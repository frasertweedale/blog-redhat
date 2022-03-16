---
tags: openshift, security, containers
---

# Creating user namespaces inside containers

Over the last year I have experimented with user namespace support in
OpenShift.  That is, making OpenShift run workloads inside a
separate user namespace.  We're trying to drive this feature
forward, but some people have reservations.  Does having processes
running as `root` inside a user namespace present an increased
security risk?  What if there are kernel bugs…

If you're worried about the security of user namespaces, OpenShift
or Kubernetes user namespace support doesn't change the game at all.
As I demonstrate in this post, you can create and use user
namespaces *inside* your workloads right now.

## Demo

I tested on OpenShift 4.9.0 in the default configuration.  So, no
explicit user namespace support.  I used a stock Fedora container
image with the following Pod spec:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: fedora
spec:
  containers:
  - name: fedora
    image: registry.fedoraproject.org/fedora:34-x86_64
    command: ["sleep", "3600"]
    securityContext:
      capabilities:
        drop:
        - CHOWN
        - DAC_OVERRIDE
        - FOWNER
        - FSETID
        - SETPCAP
        - NET_BIND_SERVICE
```

The Pod will run under the `restricted` SCC.  I explicitly drop a
number of default capabilities.

Next I created a project named `userns`, and new user `me`.

```shell
% oc new-project userns
Now using project "userns" on server "https://api.ci-ln-cih2n32-f76d1.origin-ci-int-gce.dev.openshift.com:6443".

You can add applications to this project with the 'new-app' command. For example, try:

    oc new-app rails-postgresql-example

to build a new example application in Ruby. Or use kubectl to deploy a simple Kubernetes application:

    kubectl create deployment hello-node --image=k8s.gcr.io/serve_hostname

% oc create user me
user.user.openshift.io/me created

% oc adm policy add-role-to-user edit me
clusterrole.rbac.authorization.k8s.io/edit added: "me"
```

Operating as `me` I created the pod:

```shell
% oc --as me create -f pod-fedora.yaml
pod/fedora created
```

Soon after, the pod is running.  I can see what node it is running
on, and its CRI-O container ID:

```shell
% oc get -o json pod/fedora \
    | jq '.status.phase,
          .spec.nodeName,
          .status.containerStatuses[0].containerID'
"Running"
"ci-ln-cih2n32-f76d1-sjtwq-worker-a-qr5hr"
"cri-o://d164163951604b7fc9506b3a390ec6a14c76dc6077406fc7b5ffcbf81c406f68"
```

Next I started a shell in my container.  I'll leave it running for
now, and come back to it later:

```shell
% oc exec -it pod/fedora /bin/sh
sh-5.1$
```

In another terminal, I opened a debug shell on the worker node.
Then I used `crictl` to find out the process ID (`pid`) of the main
container process.

```shell
% oc debug node/ci-ln-cih2n32-f76d1-sjtwq-worker-a-qr5hr
Starting pod/ci-ln-cih2n32-f76d1-sjtwq-worker-a-qr5hr-debug ...
To use host binaries, run `chroot /host`
Pod IP: 10.0.128.2
If you don't see a command prompt, try pressing enter.
sh-4.4# chroot /host
sh-4.4# crictl inspect d1641639 | jq .info.pid
18668
```

Next I used `pgrep` to find all the processes that share the same
set of namespaces as process `18668`.  In other words, processes
running in the same pod sandbox.

```shell
sh-4.4# pgrep --ns 18668 \
    | xargs ps -o user,pid,cmd --sort pid
USER         PID CMD
1000580+   18668 sleep 3600
1000580+   26490 /bin/sh
```

There are two processes, running under an unpriviled UID.  The UID
comes from a unique range allocated for the `userns` project.  These
two processes are the main container process (`sleep`), and the
shell that I exected a few steps ago.  As expected.

Now for the fun part.  Back to the shell we opened in `pod/fedora`.
Observe that this shell process has an empty capability set:

```shell
sh-5.1$ grep Cap /proc/$$/status
CapInh: 0000000000000000
CapPrm: 0000000000000000
CapEff: 0000000000000000
CapBnd: 0000000000000000
CapAmb: 0000000000000000
```

And yet, using `unshare(1)` I was able to create a new user
namespace.  The `-r` option says to map `root` in the new user
namespace to the user that created the namespace.  And that is
indeed what happens:

```shell
sh-5.1$ unshare -U -r
[root@fedora /]# id
uid=0(root) gid=0(root) groups=0(root),65534(nobody)
````

I confirmed it via the node debug shell.  I ran `pgrep` again, this
time restricting the search to processes in the same `pid` namespace
as process `18668`.  The `--nslist` option gives the list of
namespaces to match (all namespaces when not specified).

```shell
sh-4.4# pgrep --ns 18668 --nslist pid \
    | xargs ps -o user,pid,cmd --sort pid
USER         PID CMD
1000580+   18668 sleep 3600
1000580+   26490 /bin/sh
1000580+   36704 -sh
```

The new shell has pid `36704`.  Observe that UID `0` in the
container maps to UID `1000580000`:

```shell
sh-4.4# cat /proc/36704/uid_map
         0 1000580000          1
```

## Discussion

You can create and use user namespaces inside your containers
without any special support from OpenShift or Kubernetes.
Therefore, the idea of a OpenShift or Kubernetes feature for running
a workload in an isolated user namespace *by default* does not lead
to an increased risk of container escapes or privilege escalation
related to processes running as uid 0 in a user namespace.

This is not to gloss over the fact that other parts of a "workloads
in user namespaces" feature have to be designed and implemented with
care.  Particular aspects include pod admission and selection of the
unprivileged UIDs to map to.  But on the question of the security of
the Linux user namespaces feature itself, a first class OpenShift of
Kubernetes feature doesn't introduce any new risk.  Whatever risk
there is, is there right now.

If some critical security with user namespaces emerges and you need
an urgent mitigation, the only option is to alter the container
runtime Seccomp policies to block the `unshare(2)` syscall.  This is
an advanced topic, involving changes to node configuration.  For
details, see [*Configuring seccomp profiles*][doc-seccomp] in the
official OpenShift documentation.

[doc-seccomp]: https://docs.openshift.com/container-platform/4.8/security/seccomp-profiles.html
