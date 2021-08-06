---
tags: openshift, security, containers
---

# Demo: namespaced systemd workloads on OpenShift

I have spent much of the last year diving deep into OpenShift's
container runtime.  The goal: work out how to run systemd-based
workloads in *user namespaces* on OpenShift nodes.  The exploration
took many twists and turns.  But finally, I have achieved the goal.

In this post I recap the journey so far, and
[**demonstrate**](#demo) what I have achieved.  Then I will
summarise the path(s?) forward from here.

## The journey so far

My [previous post](2021-07-21-freeipa-on-openshift-update.html)
gives an overview of the FreeIPA on OpenShift project.  In
particular, it explains our decision to use a "monolithic"
systemd-based container.  That implementation approach exposed
capability gaps in OpenShift and led to a long running series of
investigations.  I wrote up the results of these investigations
across several blog posts, summarised here:

### [*OpenShift and user namespaces*](2020-11-05-openshift-user-namespace.html)

I observed that OpenShift (4.6 at the time) did not isolate
containers in user namespaces.  I noted that [KEP-127][] proposes
user namespace support for Kubernetes (it is [still being worked
on](https://github.com/kubernetes/enhancements/pull/2101)).  CRI-O
had also recently [added
support](https://github.com/cri-o/cri-o/pull/3944) for user
namespaces via annotations.

[KEP-127]: https://github.com/kubernetes/enhancements/issues/127

### [*User namespaces in OpenShift via CRI-O annotations*](2020-12-01-openshift-crio-userns.html)

I tested CRI-O's annotation-based user namespace support on
OpenShift 4.7 nightlies.  I found that the runtime creates a sandbox
with a user namespace and the expected UID mappings.  I also found
that it is necessary to override the `net.ipv4.ping_group_range`
sysctl.  Also, the SCC enforcement machinery does not know about
user namespaces and therefore the account that creates the container
requires the `anyuid` SCC.  These deficiencies still exist today.

### [*User namespace support in OpenShift 4.7*](2021-03-03-openshift-4.7-user-namespaces.html)

I continued my investigation after the release of OpenShift 4.7.
With the aforementioned caveats, user namespaces work.  I also noted
an inconsistent treatment of `securityContext`: specifying
`runAsUser` in the `PodSpec` maps the container's UID `0` to host
UID `0`—a dangerous configuration.

More recently, I noticed that the `userns-mode` annotation I was
using included `map-to-root=true`.  I now understand that it is this
configuration that causes this mapping behaviour.  I no longer
consider it particularly serious.  Ideally the SCC enforcement
should learn about user namespaces, and prevent unprivileged users
from creating containers that run as `root` (or other system
accounts) on the host.

### [*Multiple users in user namespaces on OpenShift*](2021-03-10-openshift-user-namespace-multi-user.html)

I verified that workloads that run processes under a variety of user
accounts work as expected in user namespaces.  I did not use a
*systemd*-based workload to verify this.

### [*systemd containers on OpenShift with cgroups v2*](2021-03-30-openshift-cgroupv2-systemd.html)

I observed that systemd-based workloads run successfully in
OpenShift when executed as UID 0 *on the host*.  Such containers can
only be created by accounts granted privileged SCCs (e.g. `anyuid`).
When running the container under other UIDs, *systemd* can't run
because it does not have write permission on the container's cgroup
directory.

### [*Using `runc` to explore the OCI Runtime Specification*](2021-05-27-oci-runtime-spec-runc.html)

I investigated how `runc` (the OCI runtime used in OpenShift)
operates, and how it creates cgroups.  I identified some potential
ways to change the ownership of the container cgroup to the
*container's* UID 0.

### [*systemd, cgroups and subuid ranges*](2021-06-09-systemd-cgroups-subuid.html)

I discovered that the systemd *transient unit API* (which `runc`
uses to create container cgroups) allows specifying a different
owner for the new cgroup.  Unfortunately, the user must be "known",
in the form of a `passwd` entity via NSSwitch.  A [proposal to relax
this requirement](https://github.com/systemd/systemd/issues/19781)
was provisionally rejected.  Other approaches include writing an
NSSwitch module to synthesise `passwd` entities for subuids, or
modifying `runc` to `chown(2)` the container cgroup after systemd
creates it.  I decided to experiment with the latter approach.


## Modifying `runc` to `chown` the container cgroup

The main challenge in modifying `runc` was getting my head around
the unfamiliar codebase.  The actual operations are straightforward.
There are two main aspects.

The first aspect is to compute the appropriate owner UID for the
cgroup, and tell it to the cgroup manager object.  I [described the
algorithm][] in a previous post.  The `config.HostRootUID()` method
already implemented this computation.  I was able to use it as-is.

[described the algorithm]: 2021-06-09-systemd-cgroups-subuid.html#determining-the-uid

The second aspect is to actually `chown(2)` the relevant cgroup
files and directories.  I previously observed systemd's behaviour
when creating units owned by arbitrary users.  systemd `chown`s the
container's cgroup directory, and the `cgroup.procs`,
`cgroup.subtree_control` and `cgroup.threads` files within that
directory.  `runc` will do the same.  The cgroup manager object
already knows the path to the container cgroup.  My implementation
uses [`filepath.Walk`][filepath.Walk] to identify and `chown` these
files to the relevant user.

[filepath.Walk]: https://golang.org/pkg/path/filepath/#Walk

## Demo

Following is a step-by-step demonstration starting with a fresh
deployment of OpenShift `4.7.20`.

```shell
% oc get clusterversion
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.7.20    True        False         8m52s   Cluster version is 4.7.20
```

::: note

There is a [regression](https://github.com/cri-o/cri-o/issues/5077)
in OpenShift 4.8.0 that prevents Pod annotations from being propagated
to container OCI configurations.  As a consequence, `runc` does not
receive the annotations that trigger the experimental behaviour.  I
filed a [pull request](https://github.com/cri-o/cri-o/pull/5078)
that fixes the issue.  The patch was accepted and the fix released
in OpenShift 4.8.4.

:::

The latent credential is the cluster `admin` user.  Where relevant,
I use the `oc --as USER` option to execute commands as other users.

```shell
% oc whoami
system:admin
```

### Install modified `runc` package

List the nodes in the cluster:

```shell
% oc get node
NAME                                       STATUS   ROLES    AGE   VERSION
ci-ln-jqbnbfk-f76d1-gnkkv-master-0         Ready    master   61m   v1.20.0+01c9f3f
ci-ln-jqbnbfk-f76d1-gnkkv-master-1         Ready    master   61m   v1.20.0+01c9f3f
ci-ln-jqbnbfk-f76d1-gnkkv-master-2         Ready    master   61m   v1.20.0+01c9f3f
ci-ln-jqbnbfk-f76d1-gnkkv-worker-a-vrbnv   Ready    worker   52m   v1.20.0+01c9f3f
ci-ln-jqbnbfk-f76d1-gnkkv-worker-b-dxk6k   Ready    worker   52m   v1.20.0+01c9f3f
ci-ln-jqbnbfk-f76d1-gnkkv-worker-c-db89w   Ready    worker   52m   v1.20.0+01c9f3f
```

For each worker node, open a node debug shell and use `rpm-ostree
override replace` to install the modified `runc` (one worker shown):

```shell
% oc debug node/ci-ln-jqbnbfk-f76d1-gnkkv-worker-a-vrbnv
Starting pod/ci-ln-jqbnbfk-f76d1-gnkkv-worker-a-vrbnv-debug ...
To use host binaries, run `chroot /host`
Pod IP: 10.0.32.2
If you don't see a command prompt, try pressing enter.
sh-4.2# chroot /host
sh-4.4# rpm-ostree override replace https://ftweedal.fedorapeople.org/runc-1.0.0-990.rhaos4.8.gitcd80260.el8.x86_64.rpm
Downloading 'https://ftweedal.fedorapeople.org/runc-1.0.0-990.rhaos4.8.gitcd80260.el8.x86_64.rpm'... done!
Checking out tree 9767154... done
No enabled rpm-md repositories.
Importing rpm-md... done
Resolving dependencies... done
Applying 1 override
Processing packages... done
Running pre scripts... done
Running post scripts... done
Running posttrans scripts... done
Writing rpmdb... done
Writing OSTree commit... done
Staging deployment... done
Upgraded:
  runc 1.0.0-96.rhaos4.8.gitcd80260.el8 -> 1.0.0-990.rhaos4.8.gitcd80260.el8
Run "systemctl reboot" to start a reboot
```

::: note

Instead of installing the modified `runc` on all worker nodes, you
could update one node and use `.spec.nodeAffinity` in the `PodSpec`
to force the pod to run on that node.

:::

Don't worry about the restart right now (it will happen in the next
step).  Exit the debug shell:

```shell
sh-4.4# exit
sh-4.2# exit

Removing debug pod ...
```

### Enable user namespaces and cgroups v2

The following `MachineConfig` enables cgroups v2 and CRI-O
annotation-based user namespace support:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: userns-cgv2
spec:
  kernelArguments:
    - systemd.unified_cgroup_hierarchy=1
    - cgroup_no_v1="all"
    - psi=1
  config:
    ignition:
      version: 3.1.0
    storage:
      files:
      - path: /etc/crio/crio.conf.d/99-crio-userns.conf
        overwrite: true
        contents:
          source: data:text/plain;charset=utf-8;base64,W2NyaW8ucnVudGltZS5ydW50aW1lcy5ydW5jXQphbGxvd2VkX2Fubm90YXRpb25zPVsiaW8ua3ViZXJuZXRlcy5jcmktby51c2VybnMtbW9kZSJdCg==
      - path: /etc/subuid
        overwrite: true
        contents:
          source: data:text/plain;charset=utf-8;base64,Y29yZToxMDAwMDA6NjU1MzYKY29udGFpbmVyczoyMDAwMDA6MjY4NDM1NDU2Cg==
      - path: /etc/subgid
        overwrite: true
        contents:
          source: data:text/plain;charset=utf-8;base64,Y29yZToxMDAwMDA6NjU1MzYKY29udGFpbmVyczoyMDAwMDA6MjY4NDM1NDU2Cg==
```

The file `/etc/crio/crio.conf.d/99-crio-userns.conf` enables CRI-O's
annotation-based user namespace support.  Its content
(base64-encoded in the `MachineConfig`) is:

```ini
[crio.runtime.runtimes.runc]
allowed_annotations=["io.kubernetes.cri-o.userns-mode"]
```

The `MachineConfig` also overrides `/etc/subuid` and `/etc/subgid`,
defining sub-id ranges for user namespaces.  The content is the same
for both files:

```
core:100000:65536
containers:200000:268435456
```

Create the `MachineConfig`:

```shell
% oc create -f machineconfig-userns-cgv2.yaml
machineconfig.machineconfiguration.openshift.io/userns-cgv2 created
```

Wait for the Machine Config Operator to apply the changes and reboot
the worker nodes:

```shell
% oc wait mcp/worker --for condition=updated --timeout=-1s
machineconfigpool.machineconfiguration.openshift.io/worker condition met
```

It will take several minutes, as worker nodes get rebooted one a time.

### Create project and user

Create a new project called `test`:

```shell
% oc new-project test
Now using project "test" on server "https://api.ci-ln-jqbnbfk-f76d1.origin-ci-int-gce.dev.openshift.com:6443".

You can add applications to this project with the 'new-app' command. For example, try:

    oc new-app ruby~https://github.com/sclorg/ruby-ex.git

to build a new example application in Python. Or use kubectl to deploy a simple Kubernetes application:

    kubectl create deployment hello-node --image=gcr.io/hello-minikube-zero-install/hello-node
```

The output shows the public domain name of this cluster:
`ci-ln-jqbnbfk-f76d1.origin-ci-int-gce.dev.openshift.com`.  We need to know
this for creating the route in the next step.

Create a user called `test`.  Grant it `admin` role on project
`test`, and the `anyuid` Security Context Constraint (SCC)
privilege:

```shell
% oc create user test
user.user.openshift.io/test created
% oc adm policy add-role-to-user admin test
clusterrole.rbac.authorization.k8s.io/admin added: "test"
% oc adm policy add-scc-to-user anyuid test
securitycontextconstraints.security.openshift.io/anyuid added to: ["test"]
```

### Create service and route

Create a service to provide HTTP access to pods matching the `app:
nginx` selector:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  selector:
    app: nginx
  ports:
    - protocol: TCP
      port: 80
```

```shell
% oc create -f service-nginx.yaml
service/nginx created
```

The following route definition will provide HTTP ingress from
outside the cluster:

```yaml
apiVersion: v1
kind: Route
metadata:
  name: nginx
spec:
  host: nginx.apps.ci-ln-jqbnbfk-f76d1.origin-ci-int-gce.dev.openshift.com
  to:
    kind: Service
    name: nginx
```

Note the `host` field.  Its value is `nginx.apps.$CLUSTER_DOMAIN`.
Change it to the proper value for your cluster, then create the
route:

```shell
% oc create -f route-nginx.yaml
route.route.openshift.io/nginx created
```

There is no pod to route the traffic to… yet.

### Create pod

The pod specification is:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels:
    app: nginx
  annotations:
    openshift.io/scc: restricted
    io.kubernetes.cri-o.userns-mode: "auto:size=65536"
spec:
  securityContext:
    sysctls:
    - name: "net.ipv4.ping_group_range"
      value: "0 65535"
  containers:
  - name: nginx
    image: quay.io/ftweedal/test-nginx:latest
    tty: true
```

Create the pod:

```shell
% oc --as test create -f pod-nginx.yaml
pod/nginx created
```

After a few seconds, the pod is running:

```shell
% oc get -o json pod/nginx | jq .status.phase
"Running"
```

Tail the pod's log.  Observe the final lines of systemd boot output
and the login prompt:

```shell
% oc logs --tail 10 pod/nginx
[  OK  ] Started The nginx HTTP and reverse proxy server.
[  OK  ] Reached target Multi-User System.
[  OK  ] Reached target Graphical Interface.
         Starting Update UTMP about System Runlevel Changes...
[  OK  ] Finished Update UTMP about System Runlevel Changes.

Fedora 33 (Container Image)
Kernel 4.18.0-305.3.1.el8_4.x86_64 on an x86_64 (console)

nginx login: %
```

::: note

Without `tty: true` in the `Container` spec, the pod won't produce
any output and `oc logs` won't have anything to show.

:::

The log tail also shows that systemd started the `nginx` service.
We already set up a `route` in the previous step.  Use `curl` to
issue an HTTP request and verify that the service is running
properly:

```shell
% curl --head \
    nginx.apps.ci-ln-jqbnbfk-f76d1.origin-ci-int-gce.dev.openshift.com
HTTP/1.1 200 OK
Server: nginx/1.18.0
Date: Wed, 21 Jul 2021 06:55:38 GMT
Content-Type: text/html
Content-Length: 5564
Last-Modified: Mon, 27 Jul 2020 22:20:49 GMT
ETag: "5f1f5341-15bc"
Accept-Ranges: bytes
Set-Cookie: 6cf5f3bc2fa4d24f45018c591d3617c3=f114e839b2eef9cdbe00856f18a06336; path=/; HttpOnly
Cache-control: private
```

### Verify sandbox

Now let's verify that the container is indeed running in a user
namespace.  Container UIDs must map to unprivileged UIDs on the
host.  Query the worker node on which the pod is running, and its
CRI-O container ID:

```shell
% oc get -o json pod/nginx | jq \
    '.spec.nodeName, .status.containerStatuses[0].containerID'
"ci-ln-jqbnbfk-f76d1-gnkkv-worker-c-db89w"
"cri-o://bf2b3d15cbd6944366e29927988ba30bc36d1efee00c28fb4c6d5b2036e462b0"
```

Start a debug shell on the node and query the PID of the container
init process:

```shell
% oc debug node/ci-ln-jqbnbfk-f76d1-gnkkv-worker-c-db89w
Starting pod/ci-ln-jqbnbfk-f76d1-gnkkv-worker-c-db89w-debug ...
To use host binaries, run `chroot /host`
Pod IP: 10.0.32.4
If you don't see a command prompt, try pressing enter.
sh-4.2# chroot /host
sh-4.4# crictl inspect bf2b3d | jq .info.pid
7759
```

Query the UID map and process tree of the container:

```shell
sh-4.4# cat /proc/7759/uid_map
         0     200000      65536
sh-4.4# pgrep --ns 7759 | xargs ps -o user,pid,cmd --sort pid
USER         PID CMD
200000      7759 /sbin/init
200000      7796 /usr/lib/systemd/systemd-journald
200193      7803 /usr/lib/systemd/systemd-resolved
200000      7806 /usr/lib/systemd/systemd-homed
200000      7807 /usr/lib/systemd/systemd-logind
200081      7809 /usr/bin/dbus-broker-launch --scope system --audit
200000      7812 /sbin/agetty -o -p -- \u --noclear --keep-baud console 115200,38400,9600 xterm
200081      7813 dbus-broker --log 4 --controller 9 --machine-id 2f2fcc4033c5428996568ca34219c72a --max-bytes 5
200000      7815 nginx: master process /usr/sbin/nginx
200999      7816 nginx: worker process
200999      7817 nginx: worker process
200999      7818 nginx: worker process
200999      7819 nginx: worker process
```

This confirms that the container has a user namespace.  The
container's UID range is `0`–`65535`, which maps to the host UID
range `200000`–`265535`.  The `ps` output shows various services
running under systemd, running under unprivileged host UIDs in this
range.

So, everything is running as expected.  One last thing: let's look
at the cgroup ownership.  Query the container's `cgroupsPath`:

```shell
sh-4.4# crictl inspect bf2b3d | jq .info.runtimeSpec.linux.cgroupsPath
"kubepods-besteffort-podc7f11ee7_e178_4dea_9d8c_c005ad648988.slice:crio:bf2b3d15cbd6944366e29927988ba30bc36d1efee00c28fb4c6d5b2036e462b0"
```

The value isn't a filesystem path.  `runc` interprets it relative to
an implementation-defined location.  We expect the cgroup directory
and the three files mentioned earlier to be owned by the user that
maps to UID `0` in the container's user namespace.  In my case,
that's `200000`.  We also expect to see scopes and slices created by
systemd **in the container** to be owned by the same user.

```shell
sh-4.4# ls -ali /sys/fs/cgroup\
/kubepods.slice/kubepods-besteffort.slice\
/kubepods-besteffort-podc7f11ee7_e178_4dea_9d8c_c005ad648988.slice\
/crio-bf2b3d15cbd6944366e29927988ba30bc36d1efee00c28fb4c6d5b2036e462b0.scope \
    | grep 200000
14755 drwxr-xr-x.  5 200000 root   0 Jul 21 06:00 .
14757 -rw-r--r--.  1 200000 root   0 Jul 21 06:00 cgroup.procs
14760 -rw-r--r--.  1 200000 root   0 Jul 21 06:00 cgroup.subtree_control
14758 -rw-r--r--.  1 200000 root   0 Jul 21 06:00 cgroup.threads
14806 drwxr-xr-x.  2 200000 200000 0 Jul 21 06:00 init.scope
14835 drwxr-xr-x. 11 200000 200000 0 Jul 21 06:15 system.slice
14922 drwxr-xr-x.  2 200000 200000 0 Jul 21 06:00 user.slice
```

Note the *inode* of the container cgroup directory: `14755`.  We can query the
inode and ownership of `/sys/fs/cgroup` *within the pod*:

```shell
% oc exec pod/nginx -- ls -ldi /sys/fs/cgroup
14755 drwxr-xr-x. 5 root nobody 0 Jul 21 06:00 /sys/fs/cgroup
```

The inode is the same; this is indeed the same cgroup.  But within the
container's user namespace, the owner appears as `root`.

This concludes the verification steps.  With my modified version of
`runc`, systemd-based workloads are indeed working properly in user
namespaces.


## Next steps

I submitted a [pull request][] with these changes.  It remains to be
seen if the general approach will be accepted, but initial feedback
is positive.  Some implementation changes are needed.  I might have
to hide the behaviour behind a feature gate (e.g. to be activated
via an annotation).  I also need to write tests and documentation.

[pull request]: https://github.com/opencontainers/runc/pull/3057

I also need to raise a ticket for the SCC issue.  The requirement
for `RunAsAny` (which is granted by the `anyuid` SCC) should be
relaxed when the sandbox has a user namespace.  The SCC enforcement
machinery needs to be enhanced to understand user namespaces, so
that unprivileged OpenShift user accounts can run workloads in them.

It would be nice to find a way to avoid the sysctl override to allow
the container user to use `ping`.  This is a much lower priority.

Alongside these matters, I can begin testing the FreeIPA container
in the test environment.  Although systemd is now working, I need to
see if the FreeIPA's constituent services will run properly.  I
anticipate that I will need to tweak the Pod configuration somewhat.
But are there more runtime capability gaps waiting to be discovered?
I don't have a particular suspicion about it, but I do need to know
for certain, one way or the other.  So expect another blog post
soon!
