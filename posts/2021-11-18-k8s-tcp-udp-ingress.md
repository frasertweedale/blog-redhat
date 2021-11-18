---
tags: kubernetes, openshift, dns
---

# Bare TCP and UDP ingress on Kubernetes

Kubernetes and OpenShift have good solutions for routing HTTP/HTTPS
traffic to the right applications.  But for ingress of bare TCP
(that is, not HTTP(S) or TLS with SNI) or UDP traffic, the situation
is more complicated.  In this post I demonstrate how to use
`LoadBalancer` Service objects to route bare TCP and UDP traffic to
your Kubernetes applications.

## Example service

For testing purposes I wrote a basic echo server.  It listens on
both TCP and UDP port 12345, and merely upper-cases and returns the
data it receives:

```python
import socketserver
import threading

def serve_tcp():
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            while True:
                data = self.rfile.readline()
                if not data:
                    break
                self.wfile.write(data.upper())

    with socketserver.TCPServer(('', 12345), Handler) as server:
        server.serve_forever()

def serve_udp():
    class Handler(socketserver.DatagramRequestHandler):
        def handle(self):
            self.wfile.write(self.rfile.read().upper())

    with socketserver.UDPServer(('', 12345), Handler) as server:
        server.serve_forever()

if __name__ == "__main__":
    threading.Thread(target=serve_tcp).start()
    threading.Thread(target=serve_udp).start()
```

The `Containerfile` adds this program to the official Fedora 35
container and declares the entry point:

```Dockerfile
FROM fedora:35-x86_64
COPY echo.py .
CMD [ "python3", "echo.py" ]
```

I published the container [image on Quay.io][image].  The Pod spec
references it:

[image]: https://quay.io/repository/ftweedal/udpecho.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: echo
  labels:
    app: echo
spec:
  containers:
  - name: server
    image: quay.io/ftweedal/udpecho:latest
```

I defined a new project namespace `echo` and created the Pod:

```shell
% oc new-project echo
Now using project "echo" on server
  "https://api.ci-ln-4ixdypb-72292.origin-ci-int-gce.dev.rhcloud.com:6443".

…

% oc create -f pod-echo.yaml
pod/echo created
```


## Create Service object

My application is not talking HTTP, so I can't use the normal
Ingress or Route facilities to get traffic to my app.

::: note

HTTP and HTTPS traffic includes the **`Host`** header, which the
ingress system can inspect to route requests to a particular Pod.
Similarly, TLS with the ***Server Name (SNI)*** extension allows TLS
traffic to be routed to a particular Pod (the Pod will perform the
handshake).  Neither approach works for UDP packets or "bare" TCP
connections.

:::

Therefore, I define a `LoadBalancer` Service.  The service
controller will ask the cloud provider to create a load balancer
that routes external traffic into the cluster.  For example, on AWS
it will (by default) create an ELB (*Elastic Load Balancer*)
instance.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: echo
spec:
  type: LoadBalancer
  selector:
    app: echo
  ports:
  - name: tcpecho
    protocol: TCP
    port: 12345
  - name: udpecho
    protocol: UDP
    port: 12345
```


OK, let's create the Service:


```shell
% oc create -f service-echo.yaml 
The Service "echo" is invalid: spec.ports: Invalid value:
[]core.ServicePort{core.ServicePort{Name:"tcpecho", Protocol:"TCP",
AppProtocol:(*string)(nil), Port:12345,
TargetPort:intstr.IntOrString{Type:0, IntVal:12345, StrVal:""},
NodePort:0}, core.ServicePort{Name:"udpecho", Protocol:"UDP",
AppProtocol:(*string)(nil), Port:12345,
TargetPort:intstr.IntOrString{Type:0, IntVal:12345, StrVal:""},
NodePort:0}}: may not contain more than 1 protocol when type is
'LoadBalancer'
```

Well, that's unfortunate.  Kubernetes does not support
`LoadBalancer` services with mixed `protocol`.  [KEP 1435][] is in
progress to address this.  It is a gated "alpha" feature [since
Kubernetes 1.20][changelog-1.20].  Cloud provider support is
currently [mixed][] but work is ongoing.

[KEP 1435]: https://github.com/kubernetes/enhancements/issues/1435
[changelog-1.20]: https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.20.md
[mixed]: https://github.com/kubernetes/enhancements/issues/1435#issuecomment-969523031

So for now, I have to create separate Service objects for UDP and
TCP ingress.  As a consequence, there will be **different public IP
addresses for TCP and UDP**.  Whether this is a problem depends on
the application.  Applications that use `SRV` records to locate
servers can handle this scenario.  Kerberos is such an application
(modern implementations, at least).  Applications that use `A` or
`AAAA` records directly might have problems.

The other downside is cost.  Cloud providers charge money for load
balancer instances.  The more you use, the more you pay.

Below is the definition of my decomposed Service objects:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: echo-udp
spec:
  type: LoadBalancer
  selector:
    app: echo
  ports:
  - name: udpecho
    protocol: UDP
    port: 12345
---
apiVersion: v1
kind: Service
metadata:
  name: echo-tcp
spec:
  type: LoadBalancer
  selector:
    app: echo
  ports:
  - name: tcpecho
    protocol: TCP
    port: 12345
```

Creating the objects now succeeds:

```shell
% oc create -f service-echo.yaml 
service/echo-udp created
service/echo-tcp created
```

To find out the hostname or IP address of the load balancer ingress
endpoint, inspect the `status` field of the Service object:

```shell
% oc get -o json service \
    | jq -c '.items[] | (.metadata.name, .status)'
"echo-tcp"
{"loadBalancer":{"ingress":[{"ip":"34.136.55.93"}]}}
"echo-udp"
{"loadBalancer":{"ingress":[{"ip":"34.71.82.205"}]}}
```

Most cloud providers report an IP address.  That includes Google
Cloud (GCP) where this cluster was deployed.  On the other hand, AWS
reports a DNS name.  Below is the result of creating my service
objects on an cluster hosted on AWS:

```shell
% oc get -o json service \
    | jq -c '.items[] | (.metadata.name, .status)'
"echo-tcp"
{"loadBalancer":{"ingress":[{"hostname":"a095e8e1ebb9e4c64ae71e0f3c688ad4-608097611.us-east-2.elb.amazonaws.com"}]}}
"echo-udp"
{"loadBalancer":{}}
```

ELB successfully created a load balancer for the TCP port.  But
something is wrong with the UDP service.  The events give more
information:

```shell
% oc get event --field-selector involvedObject.name=echo-udp
LAST SEEN   TYPE      REASON                   OBJECT             MESSAGE
94s         Normal    EnsuringLoadBalancer     service/echo-udp   Ensuring load balancer
94s         Warning   SyncLoadBalancerFailed   service/echo-udp   Error syncing load balancer: failed to ensure load balancer: Protocol UDP not supported by LoadBalancer
```

Load balancer creation failed with the error:

> Error syncing load balancer: failed to ensure load balancer:
> Protocol UDP not supported by LoadBalancer

The workaround is to add an annotation to request a *Network Load
Balancer (NLB)* instance instead of ELB (the default):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: echo-udp
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  …
```

After adding the annotation, both load balancers are configured:

```shell
% oc get -o json service \
    | jq -c '.items[] | (.metadata.name, .status)'
"echo-tcp"
{"loadBalancer":{"ingress":[{"hostname":"a473cf621de6b49dfabb6e933d0fab55-2099420434.us-east-2.elb.amazonaws.com"}]}}
"echo-udp"
{"loadBalancer":{"ingress":[{"hostname":"af7f7ed0f44c9461dbb54a9a4aedca2c-0c5861432365c726.elb.us-east-2.amazonaws.com"}]}}
```


::: note

`aws-load-balancer-type` is one of several annotations for modifying
AWS load balancer configuration.  See the [AWS Cloud Provider
documentation][] for the full list.

[AWS Cloud Provider documentation]: https://cloud-provider-aws.sigs.k8s.io/service_controller/

:::


## Testing the ingress

Using the IP address or DNS name from the `status` field, you can
use `nc(1)` to verify that the server is contactable.

```shell
% echo hello | nc 34.136.55.93 12345
HELLO

% nc --udp 34.71.82.205 12345
hello                             -- input
HELLO                             -- response
^D
```

I was able to talk to my echo server via both TCP and UDP.

::: note

If using TLS or DTLS, you could instead use OpenSSL's `s_client(1)`
to test connectivity.

:::

Use hostname instead of IP address if that is how the cloud provider
reports the ingress endpoint.


## Reaching the service via DNS

The cloud provider has set up the load balancer and the ingress IP
addresses or hostnames are reported in the `status` field of the
Service object(s).  Now you probably wish to set up DNS records so
that clients can use an established domain name to find the server.

I can't go deep into this topic in this post, because I am still
exploring this problem space myself.  But I can describe some
possible solutions at a high level.

One possibility is to teach your application controller to manage
the required DNS records.  It would monitor the Service objects and
reconcile the external DNS configuration with what it sees.  The
number and kind of records to be created will vary depending on
whether the cloud providers reports the ingress points as hostnames
or IP addresses:

Ingress endpoint    Resolution method   Records needed
----------------    -----------------   --------------
`hostname`          direct              `CNAME`
`hostname`          SRV                 `SRV`
`ip`                direct              `A`/`AAAA`
`ip`                SRV                 `A`/`AAAA` and `SRV`

Most applications have similar needs, so it would make sense to
encapsulate this behaviour in a controller that configures arbitrary
external DNS providers.  That's what the Kubernetes [ExternalDNS][]
project is all about.  [Provider stability varies][stability]; at
time of writing the only *stable* providers are Google Cloud DNS and
AWS Route 53.

[ExternalDNS]: https://github.com/kubernetes-sigs/external-dns
[stability]: https://github.com/kubernetes-sigs/external-dns#status-of-providers

Integration with OpenShift is via the [ExternalDNS Operator][].
This is an active area of work and ExternalDNS will hopefully be an
officially supported part of OpenShift in a future release.

[ExternalDNS Operator]: https://github.com/openshift/external-dns-operator

I haven't actually played with ExternalDNS yet so can't say much
more about it at this time.  Only that it looks like a very useful
solution!

Finally, recall the caveats I mentioned earlier about applications
that require ingress of **both TCP and UDP** traffic.  [KEP 1435][],
along with cloud provider support, should resolve this issue
eventually.
