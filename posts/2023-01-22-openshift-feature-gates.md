---
tags: openshift, kubernetes
---

# Setting Kubernetes feature gates in OpenShift

When Kubernetes adds a feature or changes an existing one, the new
behaviour usually starts out hidden behind a [*feature
gate*][k8s-feature-gates].  Enhancements start off in the *Alpha*
stability class, where they are usually guarded by a feature gate
that is **off by default**.  If the enhancement proves stable and
useful, after a few releases it will be promoted to *Beta*, and the
feature gate will typically default to **on**, though it can still
be disabled.  The final stage of an enhancement is *GA (generally
available)*.  If an enhancement reaches this stage, its feature gate
becomes non-operational and is [deprecated][], to be removed in a
later release.

[k8s-feature-gates]: https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/
[deprecated]: https://kubernetes.io/docs/reference/using-api/deprecation-policy/

So, in a real world deployment how do you enable or disable a
feature gate?  There are several "distributions" of Kubernetes and
various ways of doing it.  In this short post I'll demonstrate how
to set feature gates in *OpenShift*, Red Hat's container orchestration
platform which is built on Kubernetes.

## The `FeatureGate` resource

OpenShift recognises a `FeatureGate` resource type.  A single,
resource of this type named `cluster` determines the feature gates
used across the cluster.  A cluster administrator can modify
`FeatureGate/cluster` to vary the feature gates set in the cluster
from the defaults.

The `FeatureGate` resource is more than a mere list of feature gates
to enable or disable.  First, in addition to Kubernetes feature
gates, it can also set feature gates for features in OpenShift
itself, or other components or products in the cluster.  Second, it
can refer to named *feature sets*—groups of feature gates—as an
alternative to explicitly listing all the feature gates to enable or
disable.

For example, the `TechPreviewNoUpgrade` feature set enables a
collection of features that Red Hat have marked as useful and worthy
of customer *testing*, with a view to possible promotion to full
support in a future release.  Customers do not need to enable
individual feature gates but can instead enable all the *Technology
Preview* features via the following `FeatureGate` spec:

```yaml
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  name: cluster
spec:
  featureSet: TechPreviewNoUpgrade
```

::: note

Unlike the more general `MachineConfig` objects, `FeatureGate`
objects do not get composed together.  Only the single object name
`cluster` is recognised.  So there is no "lightweight" way to enable
all the feature gates from `TechPreviewNoUpgrade` plus one or two
additional feature gates.  To accomplish that, use a
`CustomNoUpgrade` with **all** the desired feature gates listed.

:::

## Enabling specific feature gates

What if the `TechPreviewNoUpgrade` feature set does not include the
feature gate you want to enable?  The `CustomNoUpgrade` feature set
allows you to list the specific feature gates you want to enable or
disable.  The following exmaple enables the
`UserNamespaceStatelessPodsSupport` feature gate:

```yaml
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  name: cluster
spec:
  featureSet: CustomNoUpgrade
  customNoUpgrade:
    enabled:
    - UserNamespacesStatelessPodsSupport
```

## Applying `FeatureGate` changes

When you change `FeatureGate/cluster`, new `MachineConfig` objects
get generated containing updated configurations of the relevant
Kubernetes and OpenShift components (e.g. *kubelet*).  Machine
Config Operator will progressively update and restart the nodes in
the cluster, while ensuring availability.

Let's see an example.  First, observe that all `MachineConfigPool`s
are up to date (`ready` count = machine `count`):

```shell
% oc get MachineConfigPool -o json | jq --compact-output \
    '.items[] | { name: .metadata.name \
                , count: .status.machineCount \
                , ready: .status.readyMachineCount}'
{"name":"master","count":3,"ready":3}
{"name":"worker","count":3,"ready":3}
```

Also observe that the `FeatureGate/cluster` object does exist, but
its spec is empty (so the default feature gate settings are used):

```shell
% oc get -o json FeatureGate/cluster | jq .spec
{}
```

Now update the `FeatureGate/cluster` object.  Assume the
`CustomNoUpgrade` configuration shown earlier resides in a file
named `featuregate-userns.yaml`.

```shell
% oc replace -f featuregate-userns.yaml
featuregate.config.openshift.io/cluster replaced
```

After a few moments, Machine Config Operator will observe the new
configuration and start updating and restarting the nodes.
Initially, all pools have zero machines in state `ready` (because
they all need updating):

```shell
% oc get MachineConfigPool -o json | jq --compact-output \
    '.items[] | { name: .metadata.name \
                , count: .status.machineCount \
                , ready: .status.readyMachineCount}'
{"name":"master","count":3,"ready":0}
{"name":"worker","count":3,"ready":0}
```

After some period of time (which will vary by cluster size), all the
nodes will have received the updated configuration and restarted.

As for verifying that the updates were applied correctly, that will
depend on which gates are being enabled or disabled.  It is out of
scope for this article.  But in terms of *how* to set feature flags
in OpenShift, I hope that this article has conveyed it clearly and
that it will be useful to others.

For further detail, see the official OpenShift [`FeatureGate`
documentation][doc-OpenShift-FeatureGate] and [`FeatureGate` object
schema][doc-OpenShift-FeatureGate-api].

[doc-OpenShift-FeatureGate]: https://docs.openshift.com/container-platform/4.12/nodes/clusters/nodes-cluster-enabling-features.html
[doc-OpenShift-FeatureGate-api]: https://docs.openshift.com/container-platform/4.12/rest_api/config_apis/featuregate-config-openshift-io-v1.html
