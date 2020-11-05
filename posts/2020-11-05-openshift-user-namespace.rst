---
tags: openshift, security
---

OpenShift and user namespaces
=============================

FreeIPA in its current form is very much not a "cloud native"
application.  Likewise the current FreeIPA container, which runs all
the required services under systemd.  My current team is working on
operationalising FreeIPA for the OpenShift container platform.  Our
initial efforts are focused around this "monolithic" container,
trying to get it to run in OpenShift, securely.  Although we
recognise we may eventually need to split up the container, it will
be a major engineering effort.  We want to have a working proof of
concept as early as possible, so that we (and others) can start the
important integration work (e.g. with Keycloak / RHSSO).

This "lift and shift" of a complex traditional application to
OpenShift results in a container that needs to run several processes
as a variety of users, including ``root``.  OpenShift isolates
containers (actually pods, which consist of one or more containers)
in their own PID namespace.  This is good, but if we are to run
container processes as ``root`` (in the container), we do not want
them to also be ``root`` on the host.  Rather, they should map to an
unprivileged account.  If we want secure multitenancy of multiple
IDM servers on a single worker node, we want the user accounts on
different IDM pods to map to disjoint sets of unprivileged users on
the host.

Linux ``user_namespaces(7)`` provide this kind of isolation.  To
what extend are user namespaces supported in OpenShift?  We needed
to find out, in order to decide how to proceed with the FreeIPA
OpenShift effort.  In this blog post I discuss my investigation and
findings.

Investigating current OpenShift behaviour
-----------------------------------------

To investigate the use (or not) of user namespaces I deployed pods
on our team's OpenShift cluster and ran commands as various users,
observing the effects on the worker node.

As cluster admin, I created a new project::

  % oc new-project test
  Now using project "test" on server "https://api.permanent.idmocp.lab.eng.rdu2.redhat.com:6443".
  ...

To avoid the cluster admin user's SCC applying to pod creation, I
created a user ``test`` and granted it the *project* ``admin`` role.
Subsequent pod creation operations will be performed as ``test``.

::

  % oc create user test
  user.user.openshift.io/test created

  % oc adm policy add-role-to-user admin test
  clusterrole.rbac.authorization.k8s.io/admin added: "test"

Next I deployed a basic pod (as user ``test``) and inspected it to
find out which worker node it was scheduled on, and the CRI-O
conatiner ID::

  % cat pod-test.yaml
  apiVersion: v1
  kind: Pod
  metadata:
    name: test
  spec:
    containers:
    - name: idm-test
      image: freeipa/freeipa-server:fedora-31
      command: ["sleep", "3600"]

  % oc --as test create -f pod-test.yaml
  pod/test created

  % oc get -o json pod test \
      | jq .spec.nodeName
  "permanent-bdd7p-worker-9r4b6"

  % oc get -o json pod test \
      | jq ".status.containerStatuses[0].containerID"
  "cri-o://a9c0cf0ac9c0c352b82a74cccf830dfa8c33aae28138808eb7bdd9d53aae2d1f"

Next, opening a debug shell on the worker node I inspected the
container to find out the PID::

  % oc debug node/permanent-bdd7p-worker-9r4b6
  Starting pod/permanent-bdd7p-worker-9r4b6-debug ...
  To use host binaries, run `chroot /host`
  Pod IP: 10.8.3.215
  If you don't see a command prompt, try pressing enter.
  sh-4.2# chroot /host
  sh-4.4# crictl inspect a9c0cf0ac | jq .pid
  1311115

Next I looked at which user the process is running under, and the
UID map of the process::

  sh-4.4# ls -l -d /proc/1311115
  dr-xr-xr-x. 9 1000620000 root 0 Nov  5 05:34 /proc/1311115

  sh-4.4# cat /proc/1311115/uid_map
           0          0 4294967295

The process was running as user ``1000620000``, and UID map has an
offset of ``0`` and a size of ``2^32``.  Which is to say, this
process is running in the same user namespace as the host.  We can
use the ``lsns`` command to confirm that everything on this
node–including all container processes–is sharing the single user
namespace::

  sh-4.4# lsns -t user
          NS TYPE  NPROCS PID USER COMMAND
  4026531837 user     296   1 root /usr/lib/systemd/systemd --switched-root --system --deserialize 18

As a result, if we use ``runAsUser`` to specify a different user
under which to run the container, the container will run as the
specified user both in the container **and on the host**.  The
following transcript demonstrates this.

Delete the pod ``test``::

  % oc delete pod test
  pod "test" deleted

Add the ``anyuid`` SCC to user ``test``::

  % oc adm policy add-scc-to-user anyuid test
  securitycontextconstraints.security.openshift.io/anyuid added to: ["test"]

Create the pod (as user ``test``)::

  % oc --as test create -f pod-test.yaml
  pod/test created

Following the same procedure as earlier, find the PID (``1381728``)
and observe that it is running as ``root`` (UID ``0``) on the host::

  sh-4.4# ls -l -d /proc/1381728
  dr-xr-xr-x. 9 root root 0 Nov  5 05:55 /proc/1381728

Consequences for FreeIPA
------------------------

Traditional applications sometimes assume they will run as ``root``
or some other "reserved" user.  FreeIPA is such a case.  Likewise,
running systemd in a container means running as UID 0 (from the
container's point of view).

The lack of user namespace use in OpenShift means that for a process
to run under a particular UID in the container, it must run as that
user on the host too.  If you application needs to be ``root``, it
will be ``root`` on the host.  Other kinds of namespaces (e.g.
``pid``, ``mnt``, ``uts`` among others) do mitigate the security
risk.  But if a rogue process can escalate privileges and escape the
other sandbox(es) the result could be catastrophic.

FreeIPA, being composed of many components, some of which are large
complex projects in their own right, and several of which are
implemented in C or leverage C libraries, has a large attack
surface.  In the absense of user namespaces the risk of container
host or co-tenant compromise—even by accident—seems high.

This all assumes that containers do not have user namespace
isolation and that FreeIPA continues to require running processes in
the FreeIPA container as fixed UIDs (probably including ``root``).
I will now discuss possible ways to eliminate these assumptions.

User namespace support in Kubernetes
------------------------------------

OpenShift is built on the Kubernetes container platform.
*Kubernetes Enhancement Proposal* `KEP-127`_ proposes user namespace
support.  The ticket has been open for 4 years and has since seen
several efforts to formalise the proposal, the most recent of which
is `kubernetes/enhancements#2101`_ (rendered_).  There have also
been several experimental implementations (e.g. `#55707`_,
`#64005`_), none of which was accepted (yet).

.. _KEP-127: https://github.com/kubernetes/enhancements/issues/127
.. _kubernetes/enhancements#2101: https://github.com/kubernetes/enhancements/pull/2101
.. _rendered: https://github.com/kubernetes/enhancements/blob/9726c1a4cc5051d8be7eaf4cb64313df60ae8751/keps/sig-node/127-usernamespaces-support/README.md
.. _#55707: https://github.com/kubernetes/kubernetes/pull/55707
.. _#64005: https://github.com/kubernetes/kubernetes/pull/64005

There has been a recent resurgence of interest and activity on this
KEP, and related discussions and pull requests.  But that has
happened before.  I believe that every new (or resurrected)
discussion or experiment can move you closer to the goal, and that
there can be several false starts before things happen.  Maybe this
time it will happen?  But maybe not.

Right now there is no final proposal and no implementation plan.  As
a team we cannot proceed on the assumption that Kubernetes will
support user namespaces.  We will certainly present our case to
OpenShift engineering internally at Red Hat, but we have to look at
other options.


User namespace support in CRI-O
-------------------------------

The `CRI-O`_ container runtime `recently implemented`_ support for
running each pod in a separate user namespace, via *annotations* on
the pod, e.g.:

.. code:: yaml

  apiVersion: v1
  kind: Pod
  metadata:
    annotations:
      io.kubernetes.cri-o.userns-mode: "auto"
  spec:
    ...

Using annotations means that no explicit support in Kubernetes is
required.  All that is required is that Kubernetes is using the
CRI-O container runtime, and CRI-O is configured to enable this
feature.  OpenShift 4.x does use CRI-O, so we're halfway there.  The
remaining step is to enable the feature in ``crio.conf``::

  allow_userns_annotation = true

The developer Giuseppe Scrivano kindly published a `screencast
showing the feature in action`_ (2 minutes).  This feature is not
yet in a supported release but is available on the v1.20 branch and
is included in OpenShift `nightly builds`_.

.. _screencast showing the feature in action: https://asciinema.org/a/351396

.. _CRI-O: https://cri-o.io/
.. _recently implemented: https://github.com/cri-o/cri-o/pull/3944
.. _nightly builds_: https://openshift-release.apps.ci.l2s4.p1.openshiftapps.com/


Splitting the FreeIPA container
-------------------------------

If Kubernetes or CRI-O user namespace support to does not solve our
problem (in our desired timeframe) then there is more pressure to
abandon the monolithic container and devote our efforts to a
"split-service" FreeIPA/IDM application.  In this scenario, the
various services that make up FreeIPA (LDAP, KDC, HTTP, CA and
others) would each run as an unprivileged process in its own
container.

This would be a big engineering effort.  Apart from FreeIPA as a
whole, most of the constituent services are also "traditional"
applications that make assumptions about their environment and
execution context.  Assumptions that do not hold in the OpenShift
container paradigm.

There is a general (albeit unevenly distributed) feeling in the team
that in the long run this effort is inevitable.  I do hold this view
myself, but also recognise that the sooner we can have a working
proof of concept, the better.  That is the main reason we are
initially pursuing the monolithic container approach.


Next steps
----------

My next step will be to install an OpenShift cluster based on the
nightly builds (which include CRI-O v1.20) and experiment with the
annotation-based user namespace support.  It seems to be what we
want, or a big step in the right direction, but we need to confirm
it.  Expect a follow-up to this article with my findings, hopefully
in the next week!
