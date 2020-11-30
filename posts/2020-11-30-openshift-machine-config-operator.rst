---
tags: openshift
---

Using the OpenShift Machine Config Operator
===========================================

In a `recent post`_ I discussed how OpenShift and Kubernetes do not
have user namespace isolation.  An `upcoming CRI-O enhancement`_
should allow pods to be run in separate user namespaces.  This
feature is controlled via *annotations*; no explicit Kubernetes
support is required.

.. _recent post: 2020-11-05-openshift-user-namespace.html
.. _upcoming CRI-O enhancement: https://github.com/cri-o/cri-o/pull/3944

To experiment with this feature I deployed an OpenShift nightly
(4.7) cluster, which uses a CRI-O v1.20 prerelease build.  But
having CRI-O v1.20 is not enough.  The feature must be explicitly
enabled in the CRI-O configuration.  This leads to the question,
*what is the proper way to manage machine configuration in an
OpenShift cluster?*  The answer is the *Machine Config Operator
(MCO)*.

The `official OpenShift documentation`_ does a good job of
introducing and explaining the MCO, so there's no need to
regurgitate it all here.  Instead I'll review the configuration,
object definitions and procedure from my CRI-O use case.

.. _official OpenShift documentation: https://access.redhat.com/documentation/en-us/openshift_container_platform/4.6/html/post-installation_configuration/post-install-machine-configuration-tasks

Configuring CRI-O via the Machine Config Operator
-------------------------------------------------

CRI-O is configured via ``/etc/crio/crio.conf`` and additional files
in the ``/etc/crio/crio.conf.d/`` directory.  Directives from
``crio.conf.d`` files have higher precedence and files are processed
in lexicographic order.

The follow configuration enables the user namespaces feature::

  [crio.runtime.runtimes.runc]
  allowed_annotations=["io.kubernetes.cri-o.userns-mode"]

I used MCO to drop that configuration snippet into the file
``/etc/crio/crio.conf.d/99-crio-userns.conf``.  First I needed the
base64 encoding of the configuration content::

  $ base64 --wrap=0 <<EOF
  [crio.runtime.runtimes.runc]
  allowed_annotations=["io.kubernetes.cri-o.userns-mode"]
  EOF
  W2NyaW8ucnVudGltZS5ydW50aW1lcy5ydW5jXQphbGxvd2VkX2Fubm90YXRpb25zPVsiaW8ua3ViZXJuZXRlcy5jcmktby51c2VybnMtbW9kZSJdCg==

Next I created ``machineconfig-crio-userns.yaml``.  This defines a
``MachineConfig``, the primary resource type handled by the MCO.
The base64 output from above is used in this file.

::

  apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: worker
    name: crio-userns
  spec:
    config:
      ignition:
        version: 3.1.0
      storage:
        files:
        - path: /etc/crio/crio.conf.d/99-crio-userns.conf
          overwrite: true
          contents:
            source: data:text/plain;charset=utf-8;base64,W2NyaW8ucnVudGltZS5ydW50aW1lcy5ydW5jXQphbGxvd2VkX2Fubm90YXRpb25zPVsiaW8ua3ViZXJuZXRlcy5jcmktby51c2VybnMtbW9kZSJdCg==

Note that the examples in the official documentation contain a lot
of extraneous fields that can be omitted.  ``MachineConfig`` objects
use the *Ignition* configuration format.  Read the `Ignition
Configuration Specification`_ to see what fields are available or
required (or not) for your use case.

.. _Ignition Configuration Specification:  https://github.com/coreos/ignition/blob/master/docs/configuration-v3_1.md

There are just a few things about this ``MachineConfig`` that I'd
like to highlight.

- For creating files, the ``mode`` field allows specifying the file
  access permissions.  The default is ``420`` (*decimal!*,
  equivalent to ``0644``); this was suitable for my use case so I
  omitted it.  But there may be many cases where the default is not
  suitable and it will be necessary to specify the ``mode``.

- This config only needs to be applied on worker nodes.  The
  ``machineconfiguration.openshift.io/role: worker`` label
  accomplishes this.  The value ``master`` can be used for
  master-only configurations.

- The file content is specified via a `"data" URI`_.  Other
  supported schemes include ``https``, ``s3`` and ``tftp``.

.. _"data" URI: https://tools.ietf.org/html/rfc2397

Next I created the ``MachineConfig`` object::

  $ oc create -f machineconfig-crio-userns.yaml
  machineconfig.machineconfiguration.openshift.io/crio-userns created

Over the next several minutes, the Machine Config Operator applied
the configuration change to all the worker nodes and restarted them.

Closing thoughts
----------------

Everything went smoothly and my impressions of MCO, from this first
"hands on" experience, are very positive.  It was a simple use case,
I admit.  But I am still very pleased that it was so easy and
everything Just Worked.  Hopefully other people have as good an
experience with MCO as I did, even for more complex configuration
changes.
