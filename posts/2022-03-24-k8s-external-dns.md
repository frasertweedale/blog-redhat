---
tags: kubernetes, dns, openshift
---

# Experimenting with ExternalDNS

DNS is a critical piece of the puzzle for exposing Kubernetes-hosted
applications to the Internet.  Running the application means nothing
if you can't get traffic to it.  Keeping public DNS records in sync
with the deployed applications is important.  The Kubernetes
[ExternalDNS][] was developed for this purpose.

[ExternalDNS]: https://github.com/kubernetes-sigs/external-dns

ExternalDNS exposes Kubernetes Services and Routes in by managing
records in external DNS providers.  It [supports many DNS
providers][providers], including the DNS services of the popular
cloud providers (AWS, Google Cloud, Azure, …).

[providers]: https://github.com/kubernetes-sigs/external-dns/blob/570b51659fdc218281e3504a558a437178465f29/README.md#status-of-providers

I have been experimenting with ExternalDNS.  My purpose is not only
to understand installation and basic usage, but also whether it can
meet the specific DNS requirements of FreeIPA, such as `SRV`
records.  This post outlines my findings.

## Operator installation

The [ExternalDNS][] controller is a Kubernetes sub-project (or
SIG—*special interest group*).  In the OpenShift ecosystem, the
[ExternalDNS Operator][] creates and manages ExternalDNS controller
instances defined by *custom resources* (CRs) of `kind:
ExternalDNS`.

The ExternalDNS Operator is available as a *Tech Preview* in
OpenShift Container Platform 4.10.  So, it is visible in the
*OperatorHub* catalogue out-of-the-box.  The [official docs][]
explain how to install the operator via the OperatorHub web console.
The instructions were easy to follow.

[ExternalDNS Operator]: https://github.com/openshift/external-dns-operator
[official docs]: https://docs.openshift.com/container-platform/4.10/networking/external_dns_operator/nw-installing-external-dns-operator.html

I prefer using the CLI where possible.  The OperatorHub system is
complex but I eventually worked out what commands and objects are
needed to install the ExternalDNS Operator from the CLI.

First, create the *operand* namespaces and RBAC objects.  The
operand namespace is where the ExternalDNS controllers (as opposed
to the ExternalDNS *Operator* controller) will live.

```shell
$ oc create ns external-dns
namespace/external-dns created

$ oc apply -f \
    https://raw.githubusercontent.com/openshift/external-dns-operator/release-0.1/config/rbac/extra-roles.yaml
role.rbac.authorization.k8s.io/external-dns-operator created
rolebinding.rbac.authorization.k8s.io/external-dns-operator created
clusterrole.rbac.authorization.k8s.io/external-dns created
clusterrolebinding.rbac.authorization.k8s.io/external-dns created
```

Next, create the `external-dns-operator` namespace where the
operator itself shall live:

```shell
% oc create ns external-dns-operator
namespace/external-dns-operator created
```

Finally create the OperatorGroup and OperatorHub Subscription
objects.  Note the contents of `external-dns-operator.yaml`:

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: external-dns-operator-
  namespace: external-dns-operator
spec:
  targetNamespaces:
  - external-dns-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: external-dns-operator
  namespace: external-dns-operator
spec:
  name: external-dns-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Create the objects:

```shell
% oc create -f external-dns-operator.yaml
operatorgroup.operators.coreos.com/external-dns-operator-8852w created
subscription.operators.coreos.com/external-dns-operator created
```

After a short delay (~1 minute for me) the operator installation
should finish.  Observe the various Kubernetes objects that
represent the running operator:

```shell
% oc get -n external-dns-operator all
NAME                                         READY   STATUS    RESTARTS      AGE
pod/external-dns-operator-594b465984-r2pc5   2/2     Running   2 (59s ago)   5m13s

NAME                                            TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
service/external-dns-operator-metrics-service   ClusterIP   172.30.151.142   <none>        8443/TCP   5m15s
service/external-dns-operator-service           ClusterIP   172.30.210.21    <none>        9443/TCP   59s

NAME                                    READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/external-dns-operator   1/1     1            1           5m14s

NAME                                               DESIRED   CURRENT   READY   AGE
replicaset.apps/external-dns-operator-594b465984   1         1         1       5m15s
```


## The `ExternalDNS` custom resource

Now that the operator is installed, we can define an `ExternalDNS`
customer resource (CR).  The operator creates an ExternalDNS
controller instance for each CR.  Here is an example
(`externaldns-test.yaml`):

```yaml
apiVersion: externaldns.olm.openshift.io/v1alpha1
kind: ExternalDNS
metadata:
  name: test
spec:
  domains:
    - filterType: Include 
      matchType: Exact 
      name: ci-ln-053y10k-72292.origin-ci-int-gce.dev.rhcloud.com
  provider:
    type: GCP
  source:
    type: Service
    service:
      serviceType:
        - LoadBalancer
    labelFilter:
      matchLabels:
        app: echo
    fqdnTemplate:
      - "{{.Name}}.ci-ln-053y10k-72292.origin-ci-int-gce.dev.rhcloud.com"
```

Breaking down the `spec`, we see the following fields:

- **`domains`** gives a rule for which domains this `ExternalDNS`
  controller must manage.  In this case, any domain name with a
  *suffix* matching the `name` subfield will match the rule.

- **`provider`** specifies the cloud provider—in this case GCP
  (Google Cloud).  For GCP there is nothing else to configure; the
  controller will use the main cluster secret to authenticate to
  Google Cloud.

- **`source`** specifies which kinds of objects the controller will
  monitor to determine the DNS records to be created/managed.  We
  configure the controller to watch Service objects.  Further
  configuration is specified in subfields:

  - **`serviceType`** restricts the type(s) of Service objects to be
    considered.

  - **`labelFilter`** can be set to further restrict the set of
    source objects by matching on the `label` field.  In this
    example, we only match Service objects with label `app: echo`.

  - **`fqdnTemplate`** specifies how to derive the fully qualified
    DNS name from the Service object.

  - **`hostnameAnnotation`** can be set to `Allow` to allow the FQDN
    to be specified via the
    `external-dns.alpha.kubernetes.io/hostname` annotation on the
    Service object.  The default value is `Ignore`, in which case
    `fqdnTemplate` is required.

Aside from `type: Service`, the `ExternalDNS` CR also recognises
`type: OpenShiftRoute`.  This type uses `Route` objects as the
source, creating `CNAME` records to alias the FQDN derived from the
`Route` object to the canonical DNS name of the ingress controller.
This isn't the behaviour I'm looking for, so the rest of this
article focuses on the behaviour for `Service` sources.


## Creating the ExternalDNS controller

Now that we have defined an `ExternalDNS` custom resource, let's
create it and see what happens.  I would like to watch the logs of
the ExternalDNS Operator during this operation.

Earlier we saw that the name of the operator Pod is
`pod/external-dns-operator-594b465984-r2pc5`.  This Pod has two
containers:

```shell
% oc get -o json -n external-dns-operator \
    pod/external-dns-operator-594b465984-r2pc5 \
    | jq '.status.containerStatuses[].name'
"kube-rbac-proxy"
"operator"
```

The container named `operator` is the one we are interested in.
We can watch its log output like so:

```shell
% oc logs -n external-dns-operator --tail 2 --follow \
    external-dns-operator-594b465984-r2pc5 operator
2022-03-22T04:41:06.625Z        INFO    controller-runtime.manager.controller.external_dns_controller   Starting workers        {"worker count": 1}
2022-03-22T04:41:06.626Z        INFO    controller-runtime.manager.controller.credentials_secret_controller     Starting workers        {"worker count": 1}
... (waiting for more output)
```

Now, in another terminal, create the `ExternalDNS` CR object:

```shell
% oc create -f externaldns-test.yaml
externaldns.externaldns.olm.openshift.io/test created
```

Log output shows the ExternalDNS Operator responding to the
appearance of the `externaldns/test` CR:

```
controller-runtime.webhook.webhooks     received request        {"webhook": "/validate-externaldns-olm-openshift-io-v1alpha1-externaldns", "UID": "cf2fb876-9ddd-45a8-88b8-5cc0344fb5cc", "kind": "externaldns.olm.openshift.io/v1alpha1, Kind=ExternalDNS", "resource": {"group":"externaldns.olm.openshift.io","version":"v1alpha1","resource":"externaldnses"}}
validating-webhook      validate create {"name": "test"}
controller-runtime.webhook.webhooks     wrote response  {"webhook": "/validate-externaldns-olm-openshift-io-v1alpha1-externaldns", "code": 200, "reason": "", "UID": "cf2fb876-9ddd-45a8-88b8-5cc0344fb5cc", "allowed": true}
external_dns_controller reconciling externalDNS {"externaldns": "/test"}
…
```

And if we look in the *operand* namespace (`external-dns`) we see
a Pod running:

```shell
% oc get -n external-dns pod
NAME                                 READY   STATUS    RESTARTS   AGE
external-dns-test-865ffff756-45d44   1/1     Running   0          54s
```

And if you want to see what an ExternalDNS *controller* is up to,
you can watch its logs:

```shell
% oc logs -n external-dns --tail 1 --follow \
    pod/external-dns-test-865ffff756-45d44
time="2022-03-23T12:26:18Z" level=info msg="All records are already up to date"
... (waiting for more output)
```


## Observing record creation

After creating the ExternalDNS instance, I found Google Cloud DNS
zone for my cluster and queried its records.  How to interact with
the cloud provider depends on which cloud provider the cluster is
hosted on, so I won't provide details.  The existing records are:

```
ci-ln-053y10k-72292.origin-ci-int-gce.dev.rhcloud.com.
  NS    21600  ns-gcp-private.googledomains.com.
ci-ln-053y10k-72292.origin-ci-int-gce.dev.rhcloud.com.
  SOA   21600  ns-gcp-private.googledomains.com.
api.ci-ln-053y10k-72292.origin-ci-int-gce.dev.rhcloud.com.
  A     60     10.0.0.2
api-int.ci-ln-053y10k-72292.origin-ci-int-gce.dev.rhcloud.com.
  A     60     10.0.0.2
*.apps.ci-ln-053y10k-72292.origin-ci-int-gce.dev.rhcloud.com.
  A     30     35.223.148.37
```

::: note

This is a *private* zone specific to my cluster.  Some non-routable
addresses appear.  I haven't figured out how to update the records
in the public zone yet.  I'm confident this is not a problem with
ExternalDNS.  Rather, I put it down to my lack of familiarity with
how to configure it, and with Google Cloud DNS.

:::

We can see that in addition to the expected `NS` and `SOA` records,
there are `A` records for the API server and a wildcard `A` record
for the main ingress controller.

Next I create the following Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: echo-tcp
  labels:
    app: echo
spec:
  type: LoadBalancer
  selector:
    app: echo
  ports:
  - name: tcpecho
    protocol: TCP
    port: 12345
```

Note that it has the `app: echo` label and has `type: LoadBalancer`,
satisfying the match criteria of the `externaldns/test` controller.
Create the service and observe its public IP address:

```shell
% oc create -f service-echo.yaml
service/echo-tcp created

% oc get service/echo-tcp \
    -o jsonpath='{.status.loadBalancer}'
{"ingress":[{"ip":"35.188.22.139"}]}
```

After creating the Service, two new records appeared in the zone:

```
echo-tcp.ci-ln-053y10k-72292.origin-ci-int-gce.dev.rhcloud.com.
  A     300    35.188.22.139
external-dns-echo-tcp.ci-ln-053y10k-72292.origin-ci-int-gce.dev.rhcloud.com.
  TXT   300    "heritage=external-dns,external-dns/owner=external-dns-test,external-dns/resource=service/test/echo-tcp"
```

The `A` record resolves the DNS name to the load balancer's IP
address.  Nothing surprising here.

The `TXT` record is the for the name `external-dns-echo-tcp.…` and
contains some metadata about the "owner" of the corresponding `A`
record.  Specifically, it identifies the Service object that is the
*source* of the record.  I am not 100% sure, but it seems to also
contain information about the ExternalDNS controller that created
the record.

When I first saw the TXT records, I theorised that the ExternalDNS
controller uses the TXT records to find "obsolete" records and
delete them.  This would occur, for example, when the Service is
deleted.  Indeed, deleting `service/echo-tcp` resulted in the
removal of both the `A` and `TXT` records.


## SRV records for `LoadBalancer` Services

Kubernetes' internal DNS system follows a [DNS-based service
discovery][dns-spec] specification.  In addition to `A`/`AAAA`
records, `SRV` records are created to locate service endpoints (port
and target DNS name) based on service name and transport protocol
(TCP or UDP).  SRV records are an important part of several
protocols as used in the real world, including Kerberos, SIP, LDAP
and XMPP.  `SRV` records have the following shape:

```
_<service>._<proto>.<domain> <ttl>
    <class> SRV <priority> <weight> <port> <target>
```

A record to locate an organisation's LDAP server might look like:

```
_ldap._tcp.example.net 300
    IN SRV 10 5 389 ldap.corp.example.net
```

[dns-spec]: https://github.com/kubernetes/dns/blob/master/docs/specification.md

Although the current system has a critical deficiency for
applications that use SRV records and operate on both TCP and UDP
(see my [previous blog post](2020-12-08-k8s-srv-limitation.html))
for most applications it works well.  Unfortunately, ExternalDNS
does not follow the DNS spec and does not create SRV records for
Services.

I am not sure why this is the case.  Perhaps ExternalDNS even
pre-dates the SRV aspects of the Kubernetes DNS specification.  Or
the need might not have been recognised or deemed sufficiently
critical to address this gap.

As it happens, there is [an abandoned pull request][srv-pr] from two years
ago that sought to add SRV record generation to ExternalDNS and
bring it in line with the spec.  The maintainers seemed receptive,
but the PR author no longer needed the feature and closed it.  So I
think there is reason to hope that the feature might eventually make
it into ExternalDNS.  Perhaps our team will drive it… we need SRV
records, and it would probably be better to enhance ExternalDNS than
to build our own solution from scratch.

[srv-pr]: https://github.com/kubernetes-sigs/external-dns/pull/1330


## SRV records for `NodePort` services

I said that ExternalDNS does not support SRV records, but there is
one exception to that.  ExternalDNS *does* create SRV records for
Services of `type: NodePort`.  This is not an appropriate solution
for our application, but we can still play with it and get a feel
for how it might work similarly for `LoadBalancer` Services.

First, we have to modify `externaldns/test` to add `NodePort` to the
list of Service types.  Update `externaldns-test.yaml`:

```yaml
…
    service:
      serviceType:
        - LoadBalancer
        - NodePort
…
```

And apply updated configuration:

```shell
% oc replace -f externaldns-test.yaml
externaldns.externaldns.olm.openshift.io/test replaced
```

Now create a new `NodePort` Service.  `service-nodeport.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nodeport
  labels:
    app: echo
spec:
  type: NodePort
  selector:
    app: echo
  ports:
  - name: nodeport
    protocol: TCP
    port: 12345
```

```shell
% oc create -f service-nodeport.yaml
service/nodeport created
```

The ExternalDNS controller log output shows it generating an `SRV`
record for the Service (wrapped for clarity):

```
…
time="…" level=debug msg="Endpoints generated from service:
default/nodeport:
[ _nodeport._tcp.nodeport.ci-ln-8hkfrzk-72292.origin-ci-int-gce.dev.rhcloud.com 0
    IN SRV  0 50 30632
    nodeport.ci-ln-8hkfrzk-72292.origin-ci-int-gce.dev.rhcloud.com []
  nodeport.ci-ln-8hkfrzk-72292.origin-ci-int-gce.dev.rhcloud.com 0
    IN A  10.0.0.4;10.0.0.5;10.0.128.3;10.0.128.2;10.0.128.4;10.0.0.3 []
]"
…
```

Unfortunately, the `SRV` record didn't actually make it to the
Google Cloud DNS zone.  I haven't worked out why, yet.  The `A`
record does get created; it's only the `SRV` record that is missing.
I'll update this article if/when I work out why the `SRV` record
goes.


## Conclusion

The ExternalDNS system is intended to automatically manage public
DNS records for Kubernetes-hosted applications.  It can
automatically create `CNAME` records for OpenShift Routes and
`A`/`AAAA` records for Services, including `LoadBalancer` services.
For applications that use `A`/`AAAA` and `CNAME` records, it works
well.

Unfortunately, `SRV` records are not well supported.  Certainly, it
does not meet the needs of typical applications that use `SRV`
records.  Operators of such applications currently have one of two
options: either manage the records manually (do not want), or
implement the required automation yourselves (e.g. in the
application's *operator* program).

The best way forward is to implement better support for `SRV`
records in ExternalDNS itself, so everyone can benefit through
shared effort and maintainership vested in the Kubernetes SIG.  I
shall file a ticket and perhaps restart discussions in the
[abandoned pull request][srv-pr] with a view to getting this
critical feature on the ExternalDNS roadmap.  The extent of
involvement of myself or my team in implementing or driving this
feature work will be determined later.
