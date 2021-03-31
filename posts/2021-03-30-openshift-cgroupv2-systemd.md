---
tags: openshift, cgroups, systemd
---

# systemd containers on OpenShift with cgroups v2

*systemd* in a container is a practical reality of migrating
nontrivial applications to container infrastructure.  It is not the
"cloud native" way, but many applications written in The Before
Times cannot be broken up and rearchitected without a huge cost.
And so, there is a demand to run containers that run systemd, which
in turn manages application services.

FreeIPA is one example.  It's traditional environment is a dedicated
Linux server (ignoring replicas).  There are *many* services which
both interact among themselves, and process requests from external
clients and other FreeIPA servers.  The engineering effort to
redesign FreeIPA as a suite of several containerised services is
expected to be very high.  Therefore our small team focused on
bringing FreeIPA to OpenShift therefore decided to pursue the
"monolithic container" approach.

Support for systemd containers in OpenShift, *without hacks*, is a
prerequisite for this approach to viable.  In this post I experiment
with systemd containers in OpenShift and share my results.


## Test application: HTTP server

To test systemd containers on OpenShift, I created a Fedora-based
container running the *nginx* HTTP server.  I enable the `nginx`
systemd and set the default command to `/sbin/init`, which is
systemd.  The server doesn't host any interesting content, but if it
responds to requests we know that systemd is working.

The `Containerfile` definition is:

```Dockerfile
FROM fedora:33-x86_64
RUN dnf -y install nginx && dnf clean all && systemctl enable nginx
EXPOSE 80
CMD [ "/sbin/init" ]
```

I built the container on my workstation and tagged it `test-nginx`.
To check that the container works, I ran it locally and performed an
HTTP request via `curl`:

```shell
% podman run --detach --publish 8080:80 test-nginx
2d8059e555c821d9ffcccd84bee88996207794957696c54e8d29787e8c33fab3

% curl --head localhost:8080
HTTP/1.1 200 OK
Server: nginx/1.18.0
Date: Thu, 25 Mar 2021 00:22:23 GMT
Content-Type: text/html
Content-Length: 5564
Last-Modified: Mon, 27 Jul 2020 22:20:49 GMT
Connection: keep-alive
ETag: "5f1f5341-15bc"
Accept-Ranges: bytes

% podman kill 2d8059e5
2d8059e555c821d9ffcccd84bee88996207794957696c54e8d29787e8c33fab3
```

The container works properly in `podman`.  I proceed to testing it
on OpenShift.

## Running (**privileged** user)

I performed my testing on an OpenShift 4.8 nightly cluster.  The
exact build is `4.8.0-0.nightly-2021-03-26-010831`.  As far as I'm
aware, with respect to systemd and cgroups there are no major
differences between OpenShift 4.7 (which is Generally Available) and
the build I'm using.  So results should be similar on OpenShift 4.7.

The Pod definition for my test service is:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  containers:
  - name: nginx
    image: quay.io/ftweedal/test-nginx:latest
```

I create the Pod, operating with the cluster `admin` credential.
After a few seconds, the pod is running:

```shell
% oc create -f pod-nginx.yaml 
pod/nginx created

% oc get -o json pod/nginx | jq .status.phase
"Running"
```

### Verifying that the service is working

`pod/nginx` is running, but it is not exposed to other pods in the
cluster, or to the outside world.  To test that the server is
working, I will expose it on the hostname
`nginx.apps.ft-48dev-5.idmocp.lab.eng.rdu2.redhat.com`.  First,
observe that performing an HTTP request from my workstation fails
because the service is not available:

```shell
% curl --head nginx.apps.ft-48dev-5.idmocp.lab.eng.rdu2.redhat.com
HTTP/1.0 503 Service Unavailable
pragma: no-cache
cache-control: private, max-age=0, no-cache, no-store
content-type: text/html
```

Now I create Service and Route objects to expose the nginx server.
The Service definition is:

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

And the Route definition is:

```yaml
apiVersion: v1
kind: Route
metadata:
  name: nginx
spec:
  host: nginx.apps.ft-48dev-5.idmocp.lab.eng.rdu2.redhat.com
  to:
    kind: Service
    name: nginx
```

I create the objects:

```shell
% oc create -f service-nginx.yaml 
service/nginx created

% oc create -f route-nginx.yaml
route.route.openshift.io/nginx created
```

After a few seconds I performed the HTTP request again, and it
succeeded:

```shell
% curl --head nginx.apps.ft-48dev-5.idmocp.lab.eng.rdu2.redhat.com
HTTP/1.1 200 OK
server: nginx/1.18.0
date: Tue, 30 Mar 2021 08:16:23 GMT
content-type: text/html
content-length: 5564
last-modified: Mon, 27 Jul 2020 22:20:49 GMT
etag: "5f1f5341-15bc"
accept-ranges: bytes
set-cookie: 6cf5f3bc2fa4d24f45018c591d3617c3=6f2f093d36d535f1dde195e08a311bda; path=/; HttpOnly
cache-control: private
```

This confirms that the systemd container is running properly on
OpenShift 4.8.


### Low-level details

Now I will inspect some low-level details of the container.  I'll do
that in a debug shell on the worker node.  So first, I query the
pod's worker node name and container ID:

```shell
% oc get -o json pod/nginx \
    | jq '.spec.nodeName,
          .status.containerStatuses[0].containerID'
"ft-48dev-5-f24l6-worker-0-q7lff"
"cri-o://d9d106cb65e4c965737ef66f15bd5b9e0988c386675e3404e24fd36e58284638"
```

Now I enter a debug shell on the worker node:

```shell
% oc debug node/ft-48dev-5-f24l6-worker-0-q7lff
Starting pod/ft-48dev-5-f24l6-worker-0-q7lff-debug ...
To use host binaries, run `chroot /host`
Pod IP: 10.8.1.64
If you don't see a command prompt, try pressing enter.
sh-4.2# chroot /host
sh-4.4# 
```

I use `crictl` to query the namespaces of the container:

```shell
sh-4.4# crictl inspect d9d106 \
        | jq .info.runtimeSpec.linux.namespaces[].type
"pid"
"network"
"ipc"
"uts"
"mount"
```

Observe that there are `pid` and `mount` namespaces (among others),
but no `cgroup` namespace.  The worker node and container are using
cgroups v1.

The `container_manage_cgroup` SELinux boolean is `off`:

```shell
sh-4.4# getsebool container_manage_cgroup
container_manage_cgroup --> off
```

Now let's see what processes are running in the container.  We can
query the PID of the initial container process via `crictl inspect`.
Then I use `pgrep(1)` with the `--ns` option, which lists processes
executing in the same namespace(s) as the specified PID:

```shell
sh-4.4# crictl inspect d9d106 | jq .info.pid
14591

sh-4.4# pgrep --ns 14591 | xargs ps -o user,pid,cmd --sort pid
USER         PID CMD
root       14591 /sbin/init
root       14625 /usr/lib/systemd/systemd-journald
systemd+   14636 /usr/lib/systemd/systemd-resolved
root       14642 /usr/lib/systemd/systemd-homed
root       14643 /usr/lib/systemd/systemd-logind
root       14646 /sbin/agetty -o -p -- \u --noclear --keep-baud console 115200,38400,9600 xterm
dbus       14647 /usr/bin/dbus-broker-launch --scope system --audit
dbus       14651 dbus-broker --log 4 --controller 9 --machine-id 2f2fcc4033c5428996568ca34219c72a --max-bytes 536870912 --max-fds 4096 --max-matches 16384 --audit
root       14654 nginx: master process /usr/sbin/nginx
polkitd    14655 nginx: worker process
polkitd    14656 nginx: worker process
polkitd    14657 nginx: worker process
polkitd    14658 nginx: worker process
polkitd    14659 nginx: worker process
polkitd    14660 nginx: worker process
polkitd    14661 nginx: worker process
polkitd    14662 nginx: worker process
```

The `PID` column shows the PIDs from the point of view of the host's
PID namespace.  The first process (PID 1 *inside* the container) is
systemd (`/sbin/init`).  systemd has started other system services,
and also nginx.

systemd is running as `root` **on the host**.  The other processes
run under various system accounts.  The container does not have its
own user namespace.  This pod was created by a privileged account,
which allows it to run as `root` on the host.

## Running (**unprivileged** user)

I created an unprivileged user called `test`, and granted it admin
privileges (so it can create pods).

```shell
% oc create user test
user.user.openshift.io/test created 

% oc adm policy add-role-to-user admin test
clusterrole.rbac.authorization.k8s.io/admin added: "test"
```

I did not grant to the `test` account any *Security Context
Constraints (SCCs)* that would allow it to run privileged containers
or use host user accounts (including `root`).

Now I create the same `nginx` pod, as this user `test`.  The pod
fails to execute:

```shell
% oc --as test create -f pod-nginx.yaml
pod/nginx created

% oc get pod/nginx
NAME    READY   STATUS             RESTARTS   AGE
nginx   0/1     CrashLoopBackOff   1          23s
```

Let's inspect the logs to see what went wrong:

```shell
% oc logs pod/nginx
%
```

There is no output.  This baffled me, at first.  Eventually I
learned that Kubernetes, by default, does not allocate
pseudo-terminal devices to containers.  You can overcome this on a
per-container basis by including `tty: true` in the Container object
definition:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  containers:
  - name: nginx
    image: quay.io/ftweedal/test-nginx:latest
    tty: true
```

With the pseudo-terminal enabled, `oc logs` now shows the error
output:

```shell
% oc logs pod/nginx
systemd v246.10-1.fc33 running in system mode. (+PAM +AUDIT +SELINUX +IMA -APPARMOR +SMACK +SYSVINIT +UTMP +LIBCRYPTSETUP +GCRYPT +GNUTLS +ACL +XZ +LZ4 +ZSTD +SECCOMP +BLKID +ELFUTILS +KMOD +IDN2 -IDN +PCRE2 default-hierarchy=unified)
Detected virtualization container-other.
Detected architecture x86-64.

Welcome to Fedora 33 (Container Image)!

Set hostname to <nginx>.
Failed to write /run/systemd/container, ignoring: Permission denied
Failed to create /kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod3bbed45f_634a_4f60_bb07_5f080c483f0f.slice/crio-90dead4cf549b844c4fb704765edfbba9e9e188b30299f484906f15d22b29fbd.scope/init.scope control group: Permission denied
Failed to allocate manager object: Permission denied
[!!!!!!] Failed to allocate manager object.
Exiting PID 1...
```

The user executing systemd does not have permissions to write the
cgroup filesystem.  Although cgroups are heirarchical, cgroups v1
does not support delegating management of part of the heirarchy to
unprivileged users.  But cgroups v2 does support this.

::: note

Set the [`SYSTEMD_LOG_LEVEL`][] environment variable to `info` or
`debug` to get more detail in the systemd log output.

[`SYSTEMD_LOG_LEVEL`]: https://www.freedesktop.org/software/systemd/man/systemd.html#%24SYSTEMD_LOG_LEVEL

:::


## Enabling cgroups v2

We can enable cgroups v2 (only) on worker nodes via the following
MachineConfig object:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: enable-cgroupv2-workers
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
    - systemd.unified_cgroup_hierarchy=1
    - cgroup_no_v1="all"
    - psi=1
```

After creating the MachineConfig, the *Machine Config Operator*
applies the configuration change and restarts each worker node, one
by one.  This occurs over several minutes.


## Running (**unprivileged**; **cgroups v2**)

After some time, all worker nodes have the updated kernel
configuration to enable cgroups v2 and disable cgroups v1.  I again
created the pod as the unprivileged `test` user.  And again, pod
execution failed.  But this time the error is different:

```shell
% oc --as test create -f pod-nginx.yaml
pod/nginx created

% oc get pod
NAME    READY   STATUS   RESTARTS   AGE
nginx   0/1     Error    1          12s

% oc logs pod/nginx
systemd v246.10-1.fc33 running in system mode. (+PAM +AUDIT +SELINUX +IMA -APPARMOR +SMACK +SYSVINIT +UTMP +LIBCRYPTSETUP +GCRYPT +GNUTLS +ACL +XZ +LZ4 +ZSTD +SECCOMP +BLKID +ELFUTILS +KMOD +IDN2 -IDN +PCRE2 default-hierarchy=unified)
Detected virtualization container-other.
Detected architecture x86-64.

Welcome to Fedora 33 (Container Image)!

Set hostname to <nginx>.
Failed to write /run/systemd/container, ignoring: Permission denied
Failed to create /init.scope control group: Permission denied
Failed to allocate manager object: Permission denied
[!!!!!!] Failed to allocate manager object.
Exiting PID 1...
```

The error suggests that the container now has its own cgroup
namespace.  I can confirm it by creating a *pod* debug container…

```shell
% oc debug pod/nginx
Starting pod/nginx-debug ...
Pod IP: 10.130.2.10
If you don't see a command prompt, try pressing enter.
sh-5.0$
```

…finding out the node and container ID…

```shell
% oc get -o json pod/nginx-debug \
    | jq '.spec.nodeName,
          .status.containerStatuses[0].containerID'
"ft-48dev-5-f24l6-worker-0-qv7kq"
"cri-o://e870d022d1c53adf94e36877312fcfef5ef0431ad9cf1fbe9c9d2ace02bee858"
```

…and analysing the container sandbox in a *node* debug shell:

```
sh-4.4# crictl inspect e870d02 \
        | jq .info.runtimeSpec.linux.namespaces[].type
"pid"
"network"
"ipc"
"uts"
"mount"
"cgroup"
```

The output confirms that the pod has a cgroup namespace.  Despite
this, the unprivileged user running systemd in the container does
not have permission to manage the namespace.  The `oc logs` output
demonstrates this.

### `container_manage_cgroups` SELinux boolean

I have one more thing to try.  The `container_manage_cgroups`
SELinux boolean was disabled on the worker nodes (per default
configuration).  Perhaps it is still needed, even when using cgroups
v2.  I enabled it on the worker node (directly from the debug shell,
for now):

```shell
sh-4.4# setsebool container_manage_cgroup on
```

I again created the nginx pod as the `test` user.  It failed with
the same error as the previous attempt, when
`container_manage_cgroup` was *off*.  So that was not the issue, or
at least not the immediate issue.

## Next steps

At this point, I have successfully enabled cgroups v2 on worker
nodes.  Container sandboxes have their own cgroup namespace.  But
inside the container, systemd fails with permission errors when it
attempts some cgroup management.

The next step is to test the systemd container in OpenShift with
cgroups v2 enabled *and* [user namespaces enabled][].  Both of these
features are necessary for securely running a complex, systemd-based
application in OpenShift.  My hope is that enabling them *together*
is the last step to getting systemd-based containers working
properly in OpenShift.  I will investigate and report the results in
an upcoming post.

[user namespaces enabled]: 2021-03-03-openshift-4.7-user-namespaces.html
