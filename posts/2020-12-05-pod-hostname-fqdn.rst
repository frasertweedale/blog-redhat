---
tags: openshift, dns
---

Pod hostnames and FQDNs
=======================

Some complex or legacy applications make strict and pervasive
assumptions about their execution environment.  Relying on the host
having a *fully qualified domain name (FQDN)* is an example of this
kind of assumption.  Indeed this is a particularly thorny kind of
assumption because there are several ways an application can query
the hostname, and they don't always agree!

It is not surprising that we have hit this particular issue during
our effort to containerise FreeIPA and operationalise it for
OpenShift.  Whereas container runtimes like Podman and Docker offer
full control of a container's FQDN, Kubernetes (and by extension
OpenShift) is more strongly opinionated.  By default, a Kubernetes
pod has only a short name, not a fully qualified domain name.  There
are limited ways to configure a pod's hostname and FQDN.
Furthermore, there is currently no way to use a pod's FQDN as the
(Kernel) hostname.

In this post I will outline the challenges and document the
attempted workarounds as we try to make FreeIPA run in OpenShift in
spite of the Kubernetes hostname restriction.


Querying the FQDN
-----------------

There are several ways an a program can query the host's hostname.

- Read ``/etc/hostname``.  The name in this file may or may not be
  fully qualified.

- Via the POSIX ``uname(2)`` system call.  The ``nodename`` field in
  the ``utsname`` struct returned by this system call is intended to
  hold a network node name.  Once again, it could be a short name or
  fully qualified.  Furthermore, on most systems it is limited to 64
  bytes.  From userland you can use the ``uname(1)`` program or
  ``uname(3)`` library routine.  The ``gethostname(2)`` and
  ``gethostname(3)`` are another way to retrieve this datum.

- On systems that use *systemd* the ``hostnamectl(1)`` program can
  be used to get or set the hostname.  Once again, the hostname is
  not necessarily fully qualified.  ``hostnamectl`` distinguishes
  between the *static* hostname (set at boot by static
  configuration) and *transient* hostname (derived from network
  configuration).  These can be queried separately.

- A program could query DNS PTR records for its non-loopback IP
  addresses.  This approach could yield zero, one or multiple FQDNs.

- The ``getaddrinfo(3)`` routine when invoked with the
  ``AI_CANONNAME`` flag can return a FQDN for a given hostname (e.g.
  the name return by ``gethostname(2)``.  This allows any *Name
  Service Switch (NSS)* plugin to provide a canonical FQDN for a
  short name.  NSS is usually configured to map hostnames using the
  data from ``/etc/hosts``, but there are other plugins including
  for *systemd-resolved*, *dns* and *sss* (SSSD).  From the command
  line, ``hostname --fqdn`` or ``hostname --all-fqdns`` will return
  result(s) from ``getaddrinfo(3)``.

Side-note: the "UTS" in ``utsname`` stands for *Unix Timesharing
System*.  Container runtimes can set a unique UTS hostname in each
container because each container (or pod) has a unique `UTS
namespace`_.

.. _UTS namespace: https://www.man7.org/linux/man-pages/man7/uts_namespaces.7.html


Auditing FreeIPA's FQDN query behaviour
---------------------------------------

In order to decide how to proceed, we first needed to audit both
FreeIPA and its dependencies to see how they query the hostname and
host FQDN.  I have published `the results of this audit`_.  It is
perhaps not exhaustive, but hopefully fairly thorough.

.. _the results of this audit: https://docs.google.com/document/d/e/2PACX-1vQzxjMw3eqkpuPfqaLbCW-GN8gwS1QvFjrs9TnPM02DMfNqBVSGapqITvAyZyxc2TN9jJShJrbqGayC/pub


Pod hostname configuration
--------------------------

We assume that the operator (human or machine) will create pods with
deterministic FQDN.  That is, it knows what the pod's FQDN should
be.  Or to be more precise, the operator knows what it wants the
application(s) running in the pod to recognise as the host FQDN.
These are not necessarily the same thing (more on that in the next
section).

First, let's investigate how OpenShift configures pod hostnames.  I
created a standalone pod with no associated services and shelled
into it to query the FQDN in various ways.  The pod configuration::

  apiVersion: v1
  kind: Pod
  metadata:
    name: test
  spec:
    containers:
    - name: test
      image: freeipa/freeipa-server:fedora-31
      command: ["sleep", "3666"]

Interactive session::

  $ oc rsh test
  sh-5.0$ uname -n
  test
  sh-5.0$ hostname
  test
  sh-5.0$ hostname --fqdn
  test
  sh-5.0$ cat /etc/hostname
  test
  sh-5.0$ hostnamectl get-hostname
  System has not been booted with systemd as init system (PID 1).
  Can't operate.
  Failed to create bus connection: Host is down

All the various ways of querying the hostname return ``test``,
except for ``hostnamectl(1)`` which fails because the container
doesn't use systemd.

What other ways can Kubernetes configure the hostname? PodSpec_ has
a ``hostname`` field for configuring the pod hostname::

  $ grep -C2 hostname pod-test.yaml 
    name: test
  spec:
    hostname: test.example.com
    containers:
    - name: test

Unfortunately, ``hostname`` only accepts a short name::

  $ oc create -f pod-test.yaml
  The Pod "test" is invalid: spec.hostname: Invalid value:
  "test.example.com": a DNS-1123 label must consist of lower case
  alphanumeric characters or '-', and must start and end with an
  alphanumeric character (e.g. 'my-name',  or '123-abc', regex used
  for validation is '[a-z0-9]([-a-z0-9]*[a-z0-9])?')

.. PodSpec: https://v1-18.docs.kubernetes.io/docs/reference/generated/kubernetes-api/v1.18/#podspec-v1-core

Some container runtimes (e.g. Podman) do allow full control over the
UTS hostname.  But it seems Kubernetes is (for the time being)
opinionated and only allows a short name.

Another ``PodSpec`` field of interest is ``subdomain``.  The
documentation says:

    If specified, the fully qualified Pod hostname will be
    "<hostname>.<subdomain>.<pod namespace>.svc.<cluster domain>". If
    not specified, the pod will not have a domainname at all.

Sounds promising.  Let's give it a go.

::

  $ grep -C2 subdomain pod-test.yaml 
    name: test
  spec:
    subdomain: subdomain
    containers:
    - name: test

::

  $ oc rsh test
  sh-5.0# uname -n 
  test
  sh-5.0# hostname
  test
  sh-5.0# hostname --fqdn
  test.subdomain.test.svc.cluster.local

``hostname --fqdn`` has returned a fully-qualified name.  This works
because the FQDN appears in ``/etc/hosts`` (associated with the IP
address of the pod).  My understanding is that *kubelet* uses a
``ConfigMap`` to inject this configuration into the pod.

::

  sh-5.0# grep subdomain /etc/hosts
  10.129.3.84     test.subdomain.test.svc.cluster.local   test

The preceding examples involve pods that I created directly.  The
configurations of pods that are created indirectly are under the
(partial) control of the corresponding controllers.  For example,
pods created by the ``StatefulSet`` controller have their
``subdomain`` field set to the ``name`` of the ``StatefulSet``.

Upcoming changes
^^^^^^^^^^^^^^^^

An `upcoming Kubernetes enhancement`_ will allow pods to specify
that its UTS hostname should be set to the pod FQDN (if the pod has
an FQDN).  This enhancement will introduces a new
``setHostnameAsFQDN`` field to the ``PodSpec``.  It is currently
scheduled to land as *alpha* in Kubernetes v1.19, move to *beta* in
v1.20 and become *stable* in v1.22.

.. _upcoming Kubernetes enhancement: https://github.com/kubernetes/enhancements/issues/1797


FreeIPA changes
---------------

With sufficient craftiness, or code changes, or network
configuration changes, or some combination thereof, it is possible
to convince a program that it's FQDN is a particular value.
Although Kubernetes and OpenShift currently offer few ways to
configure the pod (UTS) hostname, the operator could use some
mechanism (e.g. pod environment variables or a ``ConfigMap``, along
with changes to application code) to ensure that each application
instance "knows" its correct FQDN.

The hostname query audit revealed that FreeIPA asks for the host
FQDN or the system hostname (in order to check that it is a FQDN) in
lots of places and uses different query mechanisms.  If we find all
those places we can abstract away the check.  In practice this means
one common interface for FreeIPA's C code and one for the Python
code.

With hostname query logic abstracted behind these interfaces, we can
perform the lookup in whatever way is appropriate for the deployment
environment.  For a traditional deployment, we use
``gethostname(3)`` and ``getaddrinfo(3)`` with ``AI_CANONNAME``.
But in an OpenShift deployment we can instead return a value
supplied via a ``ConfigMap`` or other appropriate mechanism.

Upstream pull request `#5107`_ implemented this change.  It
consolidated the hostname query behaviour into new C and Python
routines.  It did not implement alternative behaviour for other
environments such as OpenShift, but abstracting the query behind a
single interface (for each language) makes it easy to do this later.
Whether we would use an environment variable, ``ConfigMap``, or some
other mechanism does not need to be decided at this time.

.. _#5107: https://github.com/freeipa/freeipa/pull/5107


Next steps
----------

The investigation into hostname/FQDN query behaviour of FreeIPA's
dependencies continues.  In particular, we have not yet undertaken a
thorough investigation of Samba, which is used for Active Directory
trust support.  Also, there are open questions about some other
dependencies including Dogtag and Certmonger.  It is possible that
configuration or code changes will be required to make these
programs work in environments
