---
tags: containers, openshift, security
---

# Running Pods in user namespaces without privileged SCCs

In [previous posts][] I demonstrated how to run workloads in an
isolated user namespace on OpenShift.  There are still come caveats
to doing this.  One of these relates to *Security Context
Constraints (SCCs)*, a security policy mechanism in OpenShift.  In
particular, it appeared necessary to admit the Pod via the `anyuid`
SCC, or one with similar high privileges.  This meant that although
the workload itself runs under unprivileged UIDs, the account that
creates the Pod would need privileges to create Pods that run under
arbitrary host UIDs.  This is not a desirable situation.

[previous posts]: 2021-07-22-openshift-systemd-workload-demo.html

I have investigated that matter further, and it turns out that you
*can* run a workload in a user namespace even via the default
`restricted` SCC.  But the configuration is not intuitive, and the
reasons *why* it must be configured that way are convoluted.  In
this post I explain the challenges that arise when running a user
namespaced Pod under the `restricted` SCC, and demonstrate the
solution.

::: note

This post assumes a basic knowledge of Security Context Constraints.
If you are unfamiliar with SCCs, the DevConf.cz 2022 presentation
*Introduction to Security Context Constraints* ([slides][],
[video][]) by Alberto Losada and Mario Vázquez will bring you up to
speed.

:::

[slides]: https://static.sched.com/hosted_files/devconfcz2022/d5/%5BDevConf.CZ%2022%5D%20SCCs%20Presentation.pdf
[video]: https://www.youtube.com/watch?v=MrYSUmk-nr4

## Cluster configuration

I am testing on an OpenShift 4.10 (pre-release) cluster.  Some
changes to worker node configuration are required.  The following
`MachineConfig` object defines those changes:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: idm-4-10
spec:
  kernelArguments:
    - systemd.unified_cgroup_hierarchy=1
    - cgroup_no_v1="all"
    - psi=1
  config:
    ignition:
      version: 3.1.0
    systemd:
      units:
      - name: "override-runc.service"
        enabled: true
        contents: |
          [Unit]
          Description=Install runc override
          After=network-online.target rpm-ostreed.service
          [Service]
          ExecStart=/bin/sh -c 'rpm -q runc-1.0.3-992.rhaos4.10.el8.x86_64 || rpm-ostree override replace --reboot https://ftweedal.fedorapeople.org/runc-1.0.3-992.rhaos4.10.el8.x86_64.rpm'
          Restart=on-failure
          [Install]
          WantedBy=multi-user.target
    storage:
      files:
      - path: /etc/subuid
        overwrite: true
        contents:
          source: data:text/plain;charset=utf-8;base64,Y29yZToxMDAwMDA6NjU1MzYKY29udGFpbmVyczoyMDAwMDA6MjY4NDM1NDU2Cg==
      - path: /etc/subgid
        overwrite: true
        contents:
          source: data:text/plain;charset=utf-8;base64,Y29yZToxMDAwMDA6NjU1MzYKY29udGFpbmVyczoyMDAwMDA6MjY4NDM1NDU2Cg==
      - path: /etc/crio/crio.conf.d/99-crio-userns.conf
        overwrite: true
        contents:
          source: data:text/plain;charset=utf-8;base64,W2NyaW8ucnVudGltZS53b3JrbG9hZHMub3BlbnNoaWZ0LXVzZXJuc10KYWN0aXZhdGlvbl9hbm5vdGF0aW9uID0gImlvLm9wZW5zaGlmdC51c2VybnMiCmFsbG93ZWRfYW5ub3RhdGlvbnMgPSBbCiAgImlvLmt1YmVybmV0ZXMuY3JpLW8udXNlcm5zLW1vZGUiLAogICJpby5rdWJlcm5ldGVzLmNyaS1vLmNncm91cDItbW91bnQtaGllcmFyY2h5LXJ3IiwKICAiaW8ua3ViZXJuZXRlcy5jcmktby5EZXZpY2VzIgpdCg==
```

The main parts of this `MachineConfig` are:

- The **`kernelArguments`** enable cgroupsv2, which are not strictly
  required for this demo, but are required for running systemd-based
  workloads.  

- The **`override-runc.service`** systemd unit installs a custom
  version of runc that implements the new [OCI Runtime Specification
  cgroup ownership semantics][cgroup-ownership-semantics].
  This should be the default behaviour in future versions of
  OpenShift, perhaps as soon as OpenShift 4.11.

- **`/etc/subuid`** and **`/etc/subgid`** provide a sub-id mapping range
  for CRI-O to use when creating Pods with user namespaces.

- **`/etc/crio/crio.conf.d/99-crio-userns.conf`** defines the
  `io.openshift.userns` workload type for CRI-O.  It is also not
  strictly necessary for this demo but is required for systemd-based
  workloads to run successfully.  The default CRI-O configuration in
  OpenShift 4.10 provides the `io.openshift.builder` workload type,
  which is sufficient if your workload does not need to manage
  cgroups.

[cgroup-ownership-semantics]: https://github.com/opencontainers/runtime-spec/blob/8958f93039ab90be53d803cd7e231a775f644451/config-linux.md#cgroup-ownership

Aside from the node configuration changes, I (as cluster admin) also
created project and user account to use for the subsequent steps:

```shell
% oc new-project test
Now using project "test" on server "https://api.ci-ln-5rkyxfb-72292.origin-ci-int-gce.dev.rhcloud.com:6443".
…

% oc create user test
user.user.openshift.io/test created

% oc adm policy add-role-to-user edit test
clusterrole.rbac.authorization.k8s.io/edit added: "test"
```

I did not assign any special SCCs to the `test` user account.

::: note

Remember to wait for the Machine Config Operator to finish updating
the worker nodes before proceeding with Pod creation.  You can use
`oc wait` to await this condition:

```shell
% oc wait mcp/worker \
    --for condition=updated --timeout=-1s
```

:::


## Problem demonstration

The objective is to run a Pod in a user namespace, with that Pod
being admitted via the default `restricted` SCC.  We will start with
the following Pod definition:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: fedora
  annotations:
    io.openshift.userns: "true"
    io.kubernetes.cri-o.userns-mode: "auto:size=65536"
spec:
  containers:
  - name: fedora
    image: registry.fedoraproject.org/fedora:35-x86_64
    command: ["sleep", "3600"]
```

The **`io.openshift.userns`** annotation selects the CRI-O workload
profile that we added via the `MachineConfig` above.  This profile
enables several other annotations, but does not automatically
execute the Pod in a user namespace.  For that, you must *also*
supply the **`io.kubernetes.cri-o.userns-mode`** annotation.  Its
argument tells CRI-O to automatically select unique host UID range
of size 65536 to map into the container's user namespace.

I created the Pod as user `test`:

```shell
% oc --as test create -f pod-fedora.yaml
pod/fedora created
```

Observe that it was admitted via the `restricted` SCC:

```shell
% oc get -o json pod/fedora \
    | jq '.metadata.annotations."openshift.io/scc"'
"restricted"
```

Unfortunately, the container is not running:

```shell
% oc get -o json pod/fedora \
  | jq '.status.containerStatuses[].state'
{
  "waiting": {
    "message": "container create failed: time=\"2022-02-02T05:43:34Z\" level=error msg=\"container_linux.go:380: starting container process caused: setup user: cannot set uid to unmapped user in user namespace\"\n",
    "reason": "CreateContainerError"
  }
}
```

The core error message is: ***cannot set uid to unmapped user in
user namespace***.  This arises because, in the absense of a
`runAsUser` specification in the PodSpec, the `restricted` SCC has
defaulted it to a value from the UID range assigned to the project:

```shell
% oc get -o json pod/fedora \
  | jq '.spec.containers[].securityContext.runAsUser'
1000650000
```

The project UID range allocation is recorded in the project and
namespace annotations:

```shell
% oc get -o json project/test namespace/test \
    | jq '.items[].metadata.annotations."openshift.io/sa.scc.uid-range"'
"1000650000/10000"
"1000650000/10000"
```

OpenShift allocated to project `test` a range of 10000 UIDs starting
at `1000650000`.  The error arises because UID `1000650000` is not
mapped in the user namespace.  The host UID range may be something
like `200000`–`265535`, whereas the sandbox's UID range is
`0`–`65535`.

I deleted the Pod and will try something different:

```shell
% oc delete pod/fedora
pod "fedora" deleted
```

Let's say that we want to run the container process as UID `0` *in
the Pod's user namespace*, as would be required for a systemd-based
workload.  Instead of leaving it to the SCC machinery, I'll set
`runAsUser: 0` in the PodSpec myself:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: fedora
  annotations:
    io.openshift.userns: "true"
    io.kubernetes.cri-o.userns-mode: "auto:size=65536"
spec:
  containers:
  - name: fedora
    image: registry.fedoraproject.org/fedora:35-x86_64
    command: ["sleep", "3600"]
    securityContext:
      runAsUser: 0
```

This time the `test` user cannot even create the Pod:

```shell
% oc --as test create -f pod-fedora.yaml
Error from server (Forbidden): error when creating "pod-fedora.yaml"…
```

I've trimmed the rather long error message, but the core problem is:

```
spec.containers[0].securityContext.runAsUser: Invalid value:
0: must be in the ranges: [1000650000, 1000659999]
```

The `restricted` SCC only allows `runAsUser` values that fall in the
projects assigned UID range.  And this is what we would expect.  The
problem is that the admission machinery has no awareness of user
namespaces.  It cannot discern that `runAsUser: 0` means that we
want to run as UID `0` *inside the user namespace*, whilst mapped to
an unprivileged UID on the host.

The problem is twofold.  First, we are unable to control the UID
mapping that CRI-O gives us, so that it would coincide with the
project's UID range.  Second, the SCC admission checks and
defaulting is oblivious to user namespace.  `runAsUser` is
interpreted as referring to host UIDs, and the `restricted` SCC
restricts (or defaults) us to values that are not mapped in the
Pod's user namespace.


## Solution

The `map-to-root` option in the `userns-mode` annotation provides a
solution to this dilemma.  It takes whatever value `runAsUser` is,
and ensures that that host UID gets mapped to UID `0` in the Pod
user namespace.  The updated PodSpec is:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: fedora
  annotations:
    io.openshift.userns: "true"
    io.kubernetes.cri-o.userns-mode:
      "auto:size=65536;map-to-root=true"
spec:
  securityContext:
    runAsUser: 1000650000
  containers:
  - name: fedora
    image: registry.fedoraproject.org/fedora:35-x86_64
    command: ["sleep", "3600"]
```

Now the Pod is able to run:

```shell
% oc --as test create -f pod-fedora.yaml
pod/fedora created

% oc get -o json pod/fedora \
  | jq '.spec.nodeName, .status.containerStatuses[].state'
"ci-ln-fizz88k-72292-9phfc-worker-c-7s99v"
{
  "running": {
    "startedAt": "2022-02-02T06:20:49Z"
  }
}
```

We can observe the UID mapping:

```shell
% oc rsh pod/fedora cat /proc/self/uid_map
         1     265536      65535
         0 1000650000          1
```

This shows that UID `0` in the Pod's user namespace maps to UID
`10000650000` in the parent (host) user namespace.  The remaining
UIDs `1`–`65536` in the Pod's user namespace are mapped contiguously
from UID `265536` in the host user namespace.

Objective achieved.


### Why `runAsUser` must be specified

Referring back to the PodSpec, why is it necessary to explicitly
specify `runAsUser`?  Doesn't the SCC admission machinery
automatically set the default value?  Well… yes, and no.  The SCC
machinery defaults `runAsUser` in each *container's*
`securityContext` field.  But it does not set it in the *Pod's*
`securityContext`.  And it is the *Pod* `securityContext` that CRI-O
examines when processing the `map-to-root` option.  If it is unset,
`CRI-O` will not set the mapping up properly and container(s) will
fail to run.

The consequence of this is that the user or operator creating the
Pod must first examing the Project or Namespace object to learn what
its assigned UID range is.  Then it must set the
`spec.securityContext.runAsUser` field to the start value of that
range.  The range assignment will certainly differ from project to
project so it cannot be hardcoded.  This is a bit annoying: more
work for the human operator, or more automation behaviour to
implement and maintain.

The simplest solution I can think of is to enhance the SCC
processing to also set `spec.securityContext.runAsUser` if it is
unset.  Then CRI-O would see the value it needs to see.
Alternatively CRI-O could be enhanced to check the container
`securityContext` if the `runAsUser` is not specified in the Pod
`securityContext`.  But to me this seems ill principled because
different containers (in the same Pod) could specify different
values, and there is no obvious "right" way to resolve the
ambiguities.

## Using multiple UIDs

Although I have a nice range of 65536 UIDs mapped in the Pod's user
namespace, I am not able to run processes as any UID other than `0`.
This is beacuse the `restricted` SCC forcibly omits `CAP_SETUID`
(among others) from the capability bounding set of the container
process.  Complex workloads, including any based on systemd, will
fail to run properly under such a constraint.

The simplest workaround is to admit the Pod via the `anyuid` SCC.
But that undoes the good outcome achieved in this post!

An intermediate workaround is the create a new SCC that does not
forcibly deprive containers of `CAP_SETUID`.  This entails
administrative overhead.

It also increases the attack surface.  The `setuid(2)` system call
is restricted to UIDs mapped in the UID namespace of the calling
process.  If the calling process is in an isolated user namespace
that maps to unprivileged host UIDs, it is safe (up to kernel bugs)
to grant `CAP_SETUID` to that process.  But recall that user
namespaces are still opt-in; by default Pods use the host user
namespace.  An SCC can use `MustRunAsRange` to restrict the
*initial* container process to running as a user in the project's
assigned UID range.  But if that SCC also lets containers use
`CAP_SETUID`, then it doesn't really provide more protection than
`anyuid`

A more robust solution would be to modify CRI-O to *reinstate*
`CAP_SETUID` and related capapbilities when the Pod runs in a user
namespace.  I will raise the topic with the CRI-O maintainers, as
solving this problem is important for our use case, and probably
other "legacy" workloads too.


## Conclusion

In this post I demonstrated how to run workloads in a user namespace
on OpenShift, under the default `restricted` SCC.  The `map-to-root`
option is critical to accomplishing this.  There is an unfortunate
"rough edge" in that the workload must specifically refer to the UID
range assigned to the namespace in which the Pod will live, which
means additional work for or complexity in the operator (human or
otherwise).

Despite this progress, if you need to run processes under different
UIDs in the container(s), the `restricted` UID won't work because it
deprives the container process of the `CAP_SETUID` capability.  You
must go back to admitting the workload via `anyuid` or a similar
SCC, which is a significant erosion of the security boundaries
between containers and the host.  This issue will be the subject of
future investigations.
