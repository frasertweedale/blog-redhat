---
tags: openshift, kubernetes, dns
---

Kubernetes DNS Service Discovery limitations
============================================

Kubernetes *Service* objects expose applications running in Pods as
network services.  For each combination of service name, port and
associated Pod, the Kubernetes DNS system creates a DNS ``SRV``
record that can be used for service discovery.

In this post I demonstrate a deficiency in this system that
obstructs important, real-world use cases, and sketch potential
solutions.

Overview of Kubernetes Services and DNS
---------------------------------------

The following Service definition defines an LDAP service::

  $ oc create -f service-test.yaml 
  apiVersion: v1
  kind: Service
  metadata:
    name: service-test
    labels:
      app: service-test
  spec:
    selector:
      app: service-test
    clusterIP: None
    ports:
    - name: ldap
      protocol: TCP
      port: 389

  $ oc create -f service-test.yaml                                                                                                                
  service/service-test created

The Service controller creates *Endpoint* objects to associating
each of the Service ``ports`` with each Pod matching the Service
``selector``.  If there are no matching pods, there are no
endpoints::

  $ oc get endpoints service-test
  NAME           ENDPOINTS   AGE
  service-test   <none>      8m1s

If we add a matching pod::

  $ cat pod-service-test.yaml 
  apiVersion: v1
  kind: Pod
  metadata:
    name: service-test
    labels:
      app: service-test
  spec:
    containers:
    - name: service-test
      image: freeipa/freeipa-server:fedora-31
      command: ["sleep", "3601"]

  $ oc create -f pod-service-test.yaml 
  pod/service-test created

Then the Service controller creates an endpoint that maps the
Service to the Pod::

  $ oc get endpoints service-test
  NAME           ENDPOINTS         AGE
  service-test   10.129.2.13:389   16m

  $ oc get -o yaml endpoints service-test
  apiVersion: v1
  kind: Endpoints
  metadata:
    labels:
      app: service-test
      service.kubernetes.io/headless: ""
    ... 
  subsets:
  - addresses:
    - ip: 10.129.2.13
      nodeName: ft-47dev-2-27h8r-worker-0-f8bnl
      targetRef:
        kind: Pod
        name: service-test
        namespace: test
        resourceVersion: "4556709"
        uid: 296030f5-8dff-4f69-be96-ce6f0aa12653
    ports:
    - name: ldap
      port: 389
      protocol: TCP

Cluster DNS systems (there are different implementations, e.g.
kubedns_, and the OpenShift `Cluster DNS Operator`_) use the
Endpoints objects to manage DNS records for applications running in
the cluster.  In particular, it creates ``SRV`` records mapping each
service ``name`` and ``protocol`` combination to the pod(s) that
provide that service.  The behaviour is defined in the `Kubernetes
DNS-Based Service Discovery specification`_.

.. _kubedns: https://github.com/kubernetes/dns
.. _Cluster DNS Operator:
   https://github.com/openshift/cluster-dns-operator
.. _Kubernetes DNS-Based Service Discovery specification`_:
   https://github.com/kubernetes/dns/blob/master/docs/specification.md

The SRV record owner name has the form::

  _<port>._<proto>.<service>.<ns>.svc.<zone>.

where ``ns`` is the project namespace and ``zone`` is the cluster
DNS zone.  The objects created above result in the follow ``SRV``
and ``A`` records::

  $ oc rsh service-test

  sh-5.0# dig +short SRV \
      _ldap._tcp.service-test.test.svc.cluster.local
  0 100 389 10-129-2-13.service-test.test.svc.cluster.local.

  sh-5.0# dig +short A \
      10-129-2-13.service-test.test.svc.cluster.local
  10.129.2.13

For more information above DNS ``SRV`` records, see `RFC 2782`_.

.. _RFC 2782: https://tools.ietf.org/html/rfc2782


Kubernetes SRV limitation
-------------------------

Some services operate over TCP, some over UDP.  And some operate
over *both* TCP and UDP.  Two examples are DNS and Kerberos.
``SRV`` records are of particular importance for Kerberos; they are
used (widely_, by multiple_ implementations_) for KDC discovery.

.. _widely:
   https://web.mit.edu/kerberos/krb5-devel/doc/admin/realm_config.html#hostnames-for-kdcs
.. _multiple:
   https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/7fcdce70-5205-44d6-9c3a-260e616a2f04
.. _implementations: 
   https://www.freeipa.org/page/V4/DNS_Location_Mechanism

So to host a Kerberos KDC in Kubernetes and enable service
discovery, we need two sets of SRV records: ``_kerberos._tcp`` and
``_kerberos._udp``.  And likewise for the ``kpasswd`` and
``kerberos-master`` service names.  There could be (probably are)
other protocols where a similar arrangement is required.

So, let's update the Service object and add the ``kerberos``
ServicePort specs::

  $ cat service-test.yaml 
  apiVersion: v1
  kind: Service
  metadata:
    name: service-test
    labels:
      app: service-test
  spec:
    selector:
      app: service-test
    clusterIP: None
    ports:
    - name: ldap
      protocol: TCP
      port: 389
    - name: kerberos
      protocol: TCP
      port: 88
    - name: kerberos
      protocol: UDP
      port: 88

  $ oc replace -f service-test.yaml 
  The Service "service-test" is invalid:
  spec.ports[2].name: Duplicate value: "kerberos"

Well, that's a shame.  Kerberos does not admit this important use
case.

Possible resolutions
--------------------

I am not aware of any workarounds, but I see two possible approaches
to resolving this issue.

One approach is to relax the uniqueness check.  Instead of checking
for uniqueness of ServicePort ``name``, check for the uniqueness of
the ``name``/``protocol`` pair.  This is conceptually simple but I
am not familiar enough with Kubernetes internals to judge the
feasibility or technical tradeoffs of this approach.  For users,
nothing changes (except the example above would work!)

Another approach is to add a new ServicePort field to specify the
actual DNS service label to use.  For the sake of discussion I'll
call it ``serviceName``.  It would be optional, defaulting to the
value of ``name``.  This means ``name`` can still be the "primary
key", but the approach requires *another* uniqueness check on the
``serviceName``/``protocol`` pair.  In our use case the
configuration would look like::

    ...
    ports:
    - name: ldap
      protocol: TCP
      port: 389
    - name: kerberos-tcp
      serviceName: kerberos
      protocol: TCP
      port: 88
    - name: kerberos-udp
      serviceName: kerberos
      protocol: UDP
      port: 88

From a UX perspective I prefer the first approach, because there are
no changes or additions to the ServicePort configuration schema.
But to maintain compatibility with programs that assume that
``name`` is unique (as is currently enforced), it might be necessary
to introduce a new field.

Next steps
----------

I will file a bug report and solicit feedback about this post from
Kubernetes and OpenShift DNS experts.  It might be necessary to
submit a `Kubernetes Enhancement Proposal`_ (KEP), but that seems
(as a Kubernetes outsider) a long and windy road to landing what is
a conceptually small change.

.. _Kubernetes Enhancement Proposal:
   https://github.com/kubernetes/enhancements/blob/master/keps/README.md
