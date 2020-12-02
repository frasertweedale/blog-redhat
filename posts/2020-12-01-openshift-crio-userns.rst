---
tags: openshift, security
---

User namespaces in OpenShift via CRI-O annotations
==================================================

In a recent post I covered the lack of user namespace support in
OpenShift, and discussed the `upcoming CRI-O feature`_ for user
namespacing of containers, controlled by annotations.

.. _upcoming CRI-O feature: https://github.com/cri-o/cri-o/pull/3944

I now have an OpenShift nightly cluster deployed.  It uses a
prerelease version of CRI-O v1.20, which includes this new feature.
So it's time to experiment!  This post records my investigation of
this feature.

Preliminaries
-------------

I'll skip the details of deploying the nightly (4.7) cluster
(because they are not important).  What *is* important is that I
created a ``MachineConfig`` to enable the CRI-O user namespace
annotation feature, `as described in my previous post`_.

.. _as described in my previous post: 2020-11-30-openshift-machine-config-operator.html

As in the initial investigation, I created a new user account and
project namespace for the experiments::

  % oc new-project test
  Now using project "test" on server "https://api.permanent.idmocp.lab.eng.rdu2.redhat.com:6443".

  % oc create user test
  user.user.openshift.io/test created

  % oc adm policy add-role-to-user admin test
  clusterrole.rbac.authorization.k8s.io/admin added: "test"


Creating a user namespaced pod - Attempt 1
------------------------------------------

I defined a pod that just runs ``sleep``, but uses the new
annotation to run it in a user namespace.  The ``map-to-root=true``
directive says that the "beginning" of the host uid range assigned
to the container should maps to uid 0 (i.e. ``root``) in the
container.

::

  $ cat userns-test.yaml
  apiVersion: v1
  kind: Pod
  metadata:
    name: userns-test
    annotations:
      io.kubernetes.cri-o.userns-mode: "auto:map-to-root=true"
  spec:
    containers:
    - name: userns-test
      image: freeipa/freeipa-server:fedora-31
      command: ["sleep", "3601"]

Create the pod::

  $ oc --as test create -f userns-test.yaml
  pod/userns-test created

After a few seconds, does everything look OK?

::

  $ oc get pod userns-test
  NAME          READY   STATUS              RESTARTS   AGE
  userns-test   0/1     ContainerCreating   0          14s

Hm, 14 seconds seems a long time to be stuck at
``ContainerCreating``.  What does ``oc describe`` reveal?

::

  $ oc describe pod/userns-test
  Name:         userns-test
  Namespace:    test
  Priority:     0
  Node:         ft-47dev-2-27h8r-worker-0-j4jjn/10.8.1.106
  Start Time:   Mon, 30 Nov 2020 12:41:34 +0000
  Labels:       <none>
  Annotations:  io.kubernetes.cri-o.userns-mode: auto:map-to-root=true
                openshift.io/scc: restricted
  Status:       Pending
  
  ...
  
  Events:
    Type     Reason                  Age                       From                                      Message
    ----     ------                  ----                      ----                                      -------
    Normal   Scheduled               <unknown>                                                           Successfully assigned test/userns-test to ft-47dev-2-27h8r-worker-0-j4jjn
    Warning  FailedCreatePodSandBox  <invalid> (x96 over 20m)  kubelet, ft-47dev-2-27h8r-worker-0-j4jjn  Failed to create pod sandbox: rpc error: code = Unknown desc = error creating pod sandbox with name "k8s_userns-test_test_e4f69d50-e061-46ca-b933-000bcea3363a_0": could not find enough available IDs

The node failed to create the pod sandbox.  To spare you scrolling
to read the unwrapped error message, I'll reproduce it::

  Failed to create pod sandbox: rpc error: code = Unknown
  desc = error creating pod sandbox with name
  "k8s_userns-test_test_e4f69d50-e061-46ca-b933-000bcea3363a_0":
  could not find enough available IDs

My initial reaction to this error is: **this is good!**  It *seems*
that CRI-O is attempting to create a user namespace for the
container, but cannot.  Another problem to solve, but we seem to be
on the right track.


``/etc/subuid``
---------------

I had not yet done any host configuration related to user namespace
mappings.  But I had a feeling that the ``/etc/subuid`` and
``/etc/subgid`` files would come into play.  According to
``subuid(5)``:

       Each line in /etc/subuid contains a user name and a range of
       subordinate user ids that user is allowed to use.

The description in ``subgid(5)`` is similar.

If the user that is attempting to create the containers doesn't have
an sufficient range of unused host uids and gids to use, it follows
that it will not be able to create the user namespace for the pod.

I used a debug shell to observe the current contents of
``/etc/subuid`` and ``/etc/subgid`` on worker nodes::

  sh-4.4# cat /etc/subuid
  core:100000:65536
  sh-4.4# cat /etc/subgid
  core:100000:65536

The user ``core`` owns a uid and gid range of size 65536, starting
at uid/gid 100000.  There are no other ranges defined.

At this point, I have a strong feeling we need to define uid and gid
ranges for the appropriate user, and then things will hopefully
start working.  The next question is: *who is the appropriate user*?
That is, in OpenShift which user is responsible for creating the
containers and, in this case, the user namespaces?  Again on the
worker node debug shell, I queried which user is running ``crio``::

  sh-4.4# ps -o user,pid,cmd -p $(pgrep crio)
  USER         PID CMD
  root        1791 /usr/bin/crio --enable-metrics=true --metrics-port=9537

``crio`` is running as the ``root`` user, which is not surprising.
So we will need to add mappings for the ``root`` user to the mapping
files.


``MachineConfig`` for modifying ``/etc/sub[ug]id``
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

I will create a ``MachineConfig`` to append the mappings
``/etc/subuid`` and ``/etc/subgid``.  First we need the base64
encoding of the line we want to add::

  $ echo "root:200000:268435456" | base64
  cm9vdDoyMDAwMDA6MjY4NDM1NDU2Cg==

The ``MachineConfig`` definition (note that it is scoped to the
``worker`` role)::

  $ cat machineconfig-subuid-subgid.yaml 
  apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: worker
    name: subuid-subgid
  spec:
    config:
      ignition:
        version: 3.1.0
      storage:
        files:
        - path: /etc/subuid
          append:
            - source: data:text/plain;charset=utf-8;base64,cm9vdDoyMDAwMDA6MjY4NDM1NDU2Cg==
        - path: /etc/subgid
          append:
            - source: data:text/plain;charset=utf-8;base64,cm9vdDoyMDAwMDA6MjY4NDM1NDU2Cg==

Creating the ``MachineConfig`` object::

  $ oc create -f machineconfig-subuid-subgid.yaml
  machineconfig.machineconfiguration.openshift.io/subuid-subgid created

After a few moments, checking the ``machineconfigpool/worker``
object revealed that cluster is in a degraded state::

  $ oc get -o json mcp/worker |jq '.status.conditions[-2:]'
  [
    {
      "lastTransitionTime": "2020-12-01T02:55:52Z",
      "message": "Node ft-47dev-2-27h8r-worker-0-f8bnl is reporting: \"can't reconcile config rendered-worker-a37679c5cfcefb5b0af61bb3674dccc4 with rendered-worker-3cbd4cabeedd441500c83363dbf505fd: ignition file /etc/subuid includes append: unreconcilable\"",
      "reason": "1 nodes are reporting degraded status on sync",
      "status": "True",
      "type": "NodeDegraded"
    },
    {
      "lastTransitionTime": "2020-12-01T02:55:52Z",
      "message": "",
      "reason": "",
      "status": "True",
      "type": "Degraded"
    }
  ]

The error message is::

  Node ft-47dev-2-27h8r-worker-0-f8bnl is reporting: \"can't
  reconcile config rendered-worker-a37679c5cfcefb5b0af61bb3674dccc4
  with rendered-worker-3cbd4cabeedd441500c83363dbf505fd: ignition
  file /etc/subuid includes append: unreconcilable\"",

Upon further investigation, I learned that the Machine Config
Operator does not support ``append`` operations.  This is because
are not idempotent.  So I will try again with a new machine config
that completely replaces the ``/etc/subuid`` and ``/etc/subgid``
files.

The new content shall be::

  core:100000:65536
  root:200000:268435456

The updated ``MachineConfig`` definition is::

  $ cat machineconfig-subuid-subgid.yaml
  apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: worker
    name: subuid-subgid
  spec:
    config:
      ignition:
        version: 3.1.0
      storage:
        files:
        - path: /etc/subuid
          overwrite: true
          contents:
            source: data:text/plain;charset=utf-8;base64,Y29yZToxMDAwMDA6NjU1MzYKcm9vdDoyMDAwMDA6MjY4NDM1NDU2Cg==
        - path: /etc/subgid
          overwrite: true
          contents:
            source: data:text/plain;charset=utf-8;base64,Y29yZToxMDAwMDA6NjU1MzYKcm9vdDoyMDAwMDA6MjY4NDM1NDU2Cg==

I replaced the ``MachineConfig`` object::

  $ oc replace -f machineconfig-subuid-subgid.yaml
  machineconfig.machineconfiguration.openshift.io/subuid-subgid replaced

After a few moments, the cluster is no longer degraded and the
worker nodes will be updated over the next several minutes::

  $ oc get mcp/worker
  NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
  worker   rendered-worker-a37679c5cfcefb5b0af61bb3674dccc4   False     True       False      4              0                   0                     0                      3d20h

After ``READYMACHINECOUNT`` reached ``4`` (all machines in the
``worker`` pool), I used a debug shell on one of the worker nodes to
confirm that the changes had been applied::

  $ oc debug node/ft-47dev-2-27h8r-worker-0-j4jjn
  Starting pod/ft-47dev-2-27h8r-worker-0-j4jjn-debug ...
  To use host binaries, run `chroot /host`
  Pod IP: 10.8.1.106
  If you don't see a command prompt, try pressing enter.
  sh-4.2# chroot /host
  sh-4.4# cat /etc/subuid
  core:100000:65536
  root:200000:268435456
  sh-4.4# cat /etc/subgid
  core:100000:65536
  root:200000:268435456

Looks good!


Creating a user namespaced pod - Attempt 2
------------------------------------------

It's time to create the user namespaced pod again, and see if it
succeeds this time.

::

  $ oc --as test create -f userns-test.yaml
  pod/userns-test created

Unfortunately, the same ``FailedCreatePodSandBox`` error occurred.
My ``subuid`` remedy was either incorrect, or insufficient.  I
decided to use a debug shell on the worker node to examine the
system journal.  I searched for the error string ``could not find
enough available IDs``, and found the error in the output of the
``hyperkube`` unit.  A few lines above that, there are some ``crio``
log messages, including::

  Cannot find mappings for user \"containers\": No subuid
  ranges found for user \"containers\" in /etc/subuid"

So, my mistake was defining ID map ranges for the ``root`` user.  I
should have used the ``containers`` user.  I fixed the
``MachineConfig`` definition to use the file content::

  core:100000:65536
  containers:200000:268435456

Then I replaced the ``subuid-subgid`` object and again waited for
Machine Config Operator to update the worker nodes.


Creating a user namespaced pod - Attempt 3
------------------------------------------

Once again, the container remained at ``ContainerCreating``.  But
the error was different (lines wrapped for readability)::

  Failed to create pod sandbox: rpc error:
  code = Unknown
  desc = container create failed:
    time="2020-12-01T06:40:49Z"
    level=warning
    msg="unable to terminate initProcess"
    error="exit status 1"

  time="2020-12-01T06:40:49Z"
  level=error
  msg="container_linux.go:366: starting container process caused:
    process_linux.go:472: container init caused:
      write sysctl key net.ipv4.ping_group_range:
        write /proc/sys/net/ipv4/ping_group_range: invalid argument"

After a bit of research, here is my understanding of the situation:
CRI-O successfully created the pod sandbox (which includes the user
namespace) and is now initialising it.  One of the initialisation
steps is to set the ``net.ipv4.ping_group_range`` sysctl (the
subroutine is part of ``runc``), and this is failing.  This step is
performed for all pods, but it is only failing when the pod is using
a user namespace.


``net.ipv4.ping_group_range`` and user namespaces
-------------------------------------------------

The ``net.ipv4.ping_group_range`` sysctl defines the range of group
IDs that are allowed to send ICMP Echo packets.  Setting it to the
full gid range allows ``ping`` to be used in rootless containers,
without setuid or the ``CAP_NET_ADMIN`` and ``CAP_NET_RAW``
capabilities.

The CRI-O config key ``crio.runtime.default_sysctls`` declares the
default sysctls that will be set in all containers.  The default
OpenShift CRI-O configuration sets it to the full gid range::

  sh-4.4# cat /etc/crio/crio.conf.d/00-default \
      | grep -A2 default_sysctls
  default_sysctls = [
      "net.ipv4.ping_group_range=0 2147483647",
  ]

My working hypothesis is that setting the sysctl in the
user-namespaced container fails because the gid range in the sandbox
is not ``0–2147483647`` but much smaller.  This could explain the
``invalid argument`` part of the error message.

How to overcome this?  I first thought to update the pod spec to
specify a different value for the sysctl that reflects the actual
gid range in the sandbox.  And to do that, I have to calculate what
that gid range is.

Computing the gid range
^^^^^^^^^^^^^^^^^^^^^^^

I will work on the assumption that I must refer to the range as it
appears *in the namespace*.  That assumption could be wrong, but
that's where I'm starting.

Because I am using ``map-to-root=true``, the start value of the
range should be ``0``.  The second number in the
``ping_group_range`` sysctl value is not the range size but the end
gid (inclusive).  CRI-O currently hard-codes a default user
namespace size of ``65536``.

Because the size of the uid range is a critical parameter, I shall
from now on explicitly declare the desired size in the
``userns-mode`` annotation.  This will protect the solution from
change to the default range size.  I probably won't need 65536
uids/gids but I'll stick with the default for now.

::

  io.kubernetes.cri-o.userns-mode: "auto:size=65536;map-to-root=true"

With a range of ``65536`` starting at ``0``, the desired sysctl
setting is ``net.ipv4.ping_group_range=0 65535``.

Configuring the sysctl
^^^^^^^^^^^^^^^^^^^^^^

We need ``ping`` to continue working in containers that are not
namespaced.  Therefore, overriding or clearing the CRI-O
``default_sysctls`` config is not an option.  Instead I need a way
to optionally set the ``net.ipv4.ping_group_range`` sysctl to a
specified value on a per-pod basis.

You can specify sysctls to be set in a pod via the
``spec.securityContext.sysctls`` array (see Kubernetes
`PodSecurityContext documentation`_).  I updated the pod definition
to include the sysctl::

  $ cat userns-test.yaml 
  apiVersion: v1
  kind: Pod
  metadata:
    name: userns-test
    annotations:
      openshift.io/scc: restricted
      io.kubernetes.cri-o.userns-mode: "auto:size=65536;map-to-root=true"
  spec:
    containers:
    - name: userns-test
      image: freeipa/freeipa-server:fedora-31
      command: ["sleep", "3601"]
    securityContext:
      sysctls:
      - name: "net.ipv4.ping_group_range"
        value: "0 65535"

.. _PodSecurityContext documentation: https://v1-18.docs.kubernetes.io/docs/reference/generated/kubernetes-api/v1.18/#podsecuritycontext-v1-core

As I write this, I don't know yet how CRI-O behaves when both
``default_sysctls`` and the pod spec define the same sysctl.  It
might just set the value from the pod spec, which is the behaviour I
need.  Or it might first attempt to set the value from
``default_sysctls``, and afterwards set it again to the value from
the pod spec (this will fail as before).

Time to find out!


Creating a user namespaced pod - Attempt 4
------------------------------------------

::

  $ oc --as test create -f userns-test.yaml
  pod/userns-test created

  # ... wait ...

  $ oc get pod userns-test
  NAME          READY   STATUS                 RESTARTS   AGE
  userns-test   0/1     CreateContainerError   0          118s

OK, progress was made!  It did not get stuck at
``ContainerCreating``; this time we got a ``CreateContainerError``.
This means that the CRI-O sysctl behaviour is what we were hoping
for.  As for the new error, ``oc describe`` gave the detail::

  Error: container create failed:
  time="2020-12-01T12:38:45Z"
  level=error
  msg="container_linux.go:366: starting container process caused:
    setup user: cannot set uid to unmapped user in user namespace"

My guess is that CRI-O is ignoring the fact that the pod is in a
user namespace and is attempting to execute the process using the
same uid as it would if the pod were not in a user namespace.  The
uid is outside the mapped range (``0``–``65535``).  For my next
attempt I will add ``runAsUser`` and ``runAsGroup`` to the
``securityContext``.

But first some other quick notes and observations.  First of all, a
user namespace was indeed created for this pod!

::

  sh-4.4# lsns -t user
          NS TYPE  NPROCS    PID USER   COMMAND
  4026531837 user     277      1 root   /usr/lib/systemd/systemd --switched-root --system --deserialize 16
  4026532599 user       1 684279 200000 /usr/bin/pod

We can examine the uid and gid maps for the namespace::

  sh-4.4# cat /proc/684279/uid_map
           0     200000      65536

  sh-4.4# cat /proc/684279/gid_map
           1     200001      65535
           0 1000610000          1

It surprised me that gid ``0`` is mapped to system user
``1000610000``.  I don't know what consequences this might have; for
now I am just noting it.

Because the pod sandbox does exist, I also decided to see if I could
get a debug shell::

  $ oc debug pod/userns-test
  Starting pod/userns-test-debug, command was: sleep 3601
  Pod IP: 10.129.3.170
  If you don't see a command prompt, try pressing enter.
  sh-5.0$ id
  uid=1000610000(1000610000) gid=0(root) groups=0(root),1000610000

It worked!  But the debug shell cannot be running in the user
namespace; the uid (``1000610000``) is too high.  Running ``lsns``
in my worker node debug shell confirms it; the namespace still has
only one process running in it::

  sh-4.4# lsns -t user
          NS TYPE  NPROCS    PID USER   COMMAND
  4026531837 user     282      1 root   /usr/lib/systemd/systemd --switched-root --system --deserialize 16
  4026532599 user       1 684279 200000 /usr/bin/pod


Creating a user namespaced pod - Attempt 5
------------------------------------------

I once again deleted the ``userns-test`` pod.  As proposed above, I
modified the pod security context to specify that the entry point
should be run as uid ``0`` and gid ``0``::

  $ cat userns-test.yaml
  apiVersion: v1
  kind: Pod
  metadata:
    name: userns-test
    annotations:
      openshift.io/scc: restricted
      io.kubernetes.cri-o.userns-mode: "auto:size=65536;map-to-root=true"
  spec:
    containers:
    - name: userns-test
      image: freeipa/freeipa-server:fedora-31
      command: ["sleep", "3601"]
    securityContext:
      runAsUser: 0
      runAsGroup: 0
      sysctls:
      - name: "net.ipv4.ping_group_range"
        value: "0 65535"

Here we go::

  $ oc --as test create -f userns-test.yaml
  Error from server (Forbidden): error when creating
  "userns-test.yaml": pods "userns-test" is forbidden: unable to
  validate against any security context constraint:
  [spec.containers[0].securityContext.runAsUser: Invalid value: 0:
  must be in the ranges: [1000610000, 1000619999]]

*sad trombone*

I don't have a clear idea how I could proceed.  The security context
constraint (SCC) is prohibiting the use of uid ``0`` for the
container process.  Switching to a permissive SCC might allow me to
proceed, but it would also mean using a more privileged OpenShift
user account.  Then that privileged account could then create
containers running as ``root`` *in the system user namespace*.  We
want user namespaces in OpenShift so that we can *avoid* this exact
scenario.  So resorting to a permissive SCC (e.g. ``anyuid``) feels
like the wrong way to go.

It could be that it's the only way to go for now, and that more
nuanced security policy mechanisms must be implemented before user
namespaces can be used in OpenShift to achieve the security
objective.  In any case, I'll be reaching out to other engineers and
OpenShift experts for their suggestions.

For now, I'm calling it a day!  See you soon for the next episode.
