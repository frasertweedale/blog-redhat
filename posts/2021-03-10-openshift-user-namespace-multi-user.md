---
tags: openshift, security, containers
---

# Multiple users in user namespaces on OpenShift

In the [previous
post](2021-03-03-openshift-4.7-user-namespaces.html) I confirmed
that user namespaced pods are working in OpenShift 4.7.  There are
some rough edges, and the feature must be explicitly enabled in the
cluster.  But it fundamentally works.

One area I identified for a follow-up investigation is the behaviour
of containers that execute multiple processes as different users.
The correct and "expected" behaviour is important for
*systemd*-based containers (among other scenarios).  I did not
anticipate any problems, but this is something we need to verify as
part of the effort to bring FreeIPA to OpenShift.  This post records
my steps to verify that multi-user containers work as needed in user
namespaces on OpenShift.


## Setup

### Cluster configuration

I configured the cluster as recorded in my earlier post, [*User
namespaces in OpenShift via CRI-O
annotations*](2020-12-01-openshift-crio-userns.html).

### Test program

I wrote a small Python program to serve as the container entrypoint.
This program will run as `root` (in the namespace).  For each of
several hardcoded system accounts, it invokes `fork(2)` to duplicate
the process.  The child process executes `setuid(2)` to switch user
account, then `execlp(3)` to replace itself with the `sleep(1)`
program.  The duration to sleep depends on the UID of the system
account that executes it.

Outside the container, we will be able to observe whether the
program (and its child processes) are running, and which user
accounts they are running under.

The source of the test program:

```python
import os, pwd, time

users = ['root', 'daemon', 'operator', 'nobody', 'mail']

for user in users:
    ent = pwd.getpwnam(user)
    uid = ent.pw_uid
    if os.fork() != 0:
        os.setuid(uid)
        os.execlp('sleep', 'sleep', str(3000 + uid))

time.sleep(3600)
```

### Container

The `Containerfile` is simple.  Based on `fedora:33-x86_64`, it
copies the Python program into the container and defines the entry
point:

```Dockerfile
FROM fedora:33-x86_64
COPY test_multiuser.py .
ENTRYPOINT ["python3", "test_multiuser.py"]
```

I built the container and pushed it to
[`quay.io/ftweedal/test-multiuser:latest`][container].

[container]: https://quay.io/repository/ftweedal/test-multiuser


### Pod specification

The pod YAML is:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: multiuser-test
  annotations:
    openshift.io/scc: restricted
    io.kubernetes.cri-o.userns-mode:
      "auto:size=65536;map-to-root=true"
spec:
  containers:
  - name: multiuser-test
    image: quay.io/ftweedal/test-multiuser:latest
    securityContext:
      runAsUser: 0
      runAsGroup: 0
  securityContext:
    sysctls:
    - name: "net.ipv4.ping_group_range"
      value: "0 65535"
```

The `io.kubernetes.cri-o.userns-mode` annotation tells CRI-O to run
the pod in a user namespace.  The `runAsUser` and `runAsGroup`
fields tell CRI-O to execute the entry point process as `root`
(inside the namespace).


## Verification

I created the pod:

```shell
% oc --as test create -f multiuser-test.yaml
pod/multiuser-test created
```

After a short time, I queried the status, node
and container ID of the pod:

```shell
% oc get -o json pod multiuser-test \
    | jq '.status.phase,
          .spec.nodeName,
          .status.containerStatuses[0].containerID'
"Running"
"ft-47dev-1-4kplg-worker-0-qjfcj"
"cri-o://ee693645f41aa5b54b890862778f173ebaf465f741231426c9e80237aa60660b"
```

Next I opened a debug shell on the worker node and queried the
container PID (process ID):

```shell
% oc debug node/ft-47dev-1-4kplg-worker-0-qjfcj
Starting pod/ft-47dev-1-4kplg-worker-0-qjfcj-debug ...
To use host binaries, run `chroot /host`
Pod IP: 10.8.0.165
If you don't see a command prompt, try pressing enter.
sh-4.2# chroot /host
sh-4.4# crictl inspect ee69364 | jq .info.pid
2445729
```

I viewed the user map of the process:

```shell
sh-4.4# cat /proc/2445729/uid_map
         0     265536      65536
```

This confirms that the container is in a user namespace.  The UID
range `0`–`65535` in the container is mapped to `265536`–`331071` on
the host.  That is in line with what I expect.

Now let's see what else is running in that namespace.  We can use
`pgrep(1)` with the `--ns PID` option, which selects all processes
in the same namespace(s) as `PID`.  Then `ps(1)` can tell us which
users are executing those processes.

```shell
sh-4.4# pgrep --ns 2445729 \
        | xargs ps -o user,pid,cmd --sort pid
USER         PID CMD
265536   2445729 sleep 3000
265538   2445766 sleep 3002
265547   2445767 sleep 3011
331070   2445768 sleep 68534
265544   2445769 sleep 3008
265536   2445770 python3 stuff.py
```

The entry point spawned the expected 5 child processes.  Each is
running as a different user.  This is the *host* view of the
processes.  Subtracting the base of the `uid_map` from each UID, we
observe that the UIDs *in the namespace* are: `0`, `2`, `11`,
`65534` and `8`.  These are the UIDs of the five accounts declared
in the test program.


## Conclusion

Containers that use multiple users work as expected when using user
namespaces in OpenShift.

The so far unstated assumption is that the mapped UID range includes
all the UIDs actually used by the containerised application.
Different applications use different UIDs, and different operating
systems define different UIDs.  So take care that the UID map hinted
by the CRI-O annotation suits the container and application.

Note that mapped UID ranges in Linux need not be contiguous (either
outside or inside the container).  That is, a process may have
multiple lines in its `/proc/<PID>/uid_map`, mapping multiple,
non-overlapping and not-necessarily-adjacent ranges.  But I am
talking about the Linux user namespace feature here.  I have not yet
checked whether CRI-O + OpenShift admits this more complex scenario.
But it is fundamentally possible.

The `nobody` user in Fedora has UID `65534`.  Therefore a "simple
mapping" must have a size not less than *65535* to use the `nobody`
account in a user namespaced pod.  OK, let's round that up to *65536
= 2^16^*.  With a total UID space of *2^16+16^*, you are limited to
less than *65536* separate mappings.  It sounds like a lot, but this
limit could be a problem in large, complex environments.  But most
applications will use only a handful of UIDs.  Non-contiguous UID
mapping could dramatically increase the number of ranges available,
by not mapping UIDs that applications do not use.  But there is
substantial complexity in defining and managing non-contiguous UID
mappings.
