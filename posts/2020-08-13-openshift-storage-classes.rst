---
tags: openshift
---

Dynamic volume provisioning with OpenShift storage classes
==========================================================

For containerised applications that require persistent storage, the
Kubernetes ``PersistentVolumeClaim`` (PVC) object provides the link
between a ``PersistentVolume`` (PV) and the pod.  When scaling such
an application or even deploying it the first time, the operator
(human or otherwise) has to create the PVC; the pod specification
can then refer to it.

For example, a ``StatefulSet`` object can optionally specify
``volumeClaimTemplates`` alongside the pod ``template``.  As the
application creates pods, so will it create the associated PVCs
according to the defined templates.

But PVCs need PVs to bind to.  Can these also be created on the fly?
And if so, how can we abstract over the details of the underlying
storage provider(s), which may vary from cluster to cluster?  In
this post I provide an overview of *storage classes*, which solve
these problems.


Creating volumes
----------------

A cluster can provide a variety of types of volumes: Ceph, NFS,
``hostPath``, iSCSI and several more.  Storage types of the
infrastructure the cluster is deployed in may also be available,
e.g. AWS EBS, Azure Disk, GCE PersistentDisk (PD), Cinder
(OpenStack), etc.

Creating a ``PersistentVolume`` requires knowing about what volume
types are supported, and possibly additional details about that
storage type.  For example, to create a PV based on a GCE PD:

.. code:: yaml

  apiVersion: v1
  kind: PersistentVolume
  metadata:
    name: pv-test
  spec:
    capacity:
      storage: 100Gi
    accessModes:
    - ReadWriteOnce
    gcePersistentDisk:
      pdName: my-data-disk
      fsType: ext4
    nodeAffinity:
      required:
        nodeSelectorTerms:
        - matchExpressions:
          - key: failure-domain.beta.kubernetes.io/zone
            operator: In
            values:
            - us-central1-a
            - us-central1-b

Creating this PV required:

- knowing that the cluster provides the GCE PD volume type
- knowing the name and region/zones of the PD to use

Having to know these details and encoding them into an application's
deployment manifests imposes a greater burden on administrators, or
necessitates more complex operators, or results in a less portable
application.  Or some combination of those outcomes.

Storage classes
---------------

What we really want is to abstract over the storage implementations.
We want to able to specify some high-level characteristics of the
storage (e.g. block or file, fast or slow?).  This is what *storage
classes* provide.  Then when we create a PVC, we can specify the
desired capacity and class, and the cluster should *dynamically
provision* an appropriate volume.  As a result, applications are
simpler to deploy and more portable.

To see the storage classes available in a cluster::

  ftweedal% oc get storageclass
  NAME                 PROVISIONER            RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
  standard (default)   kubernetes.io/cinder   Delete          WaitForFirstConsumer   true                   28d

This cluster has only one storage class, called ``standard``.  It is
also the default storage class for this cluster.  To use dynamic
provisioning, in the PVC spec instead of ``volumeName`` specify
``storageClassName``:

.. code:: yaml

  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: pvc-test
  spec:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi
    storageClassName: standard

If you want to use the default storage class, you can even omit the
``storageClassName`` field:

.. code:: yaml

  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: pvc-test
  spec:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi

Dynamic provisioning in action
------------------------------

Let's see what actually happens when we use dynamic provisioning.
We will observe what objects are created and how their status
changes as we create, use and delete a PVC that uses the default
storage class.

First let's see what PVs exist::

  ftweedal% oc get pv
  NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS    CLAIM                                             STORAGECLASS   REASON    AGE
  pvc-d3bc7c81-8a24-4318-a914-296dbdc5ec3f   100Gi      RWO            Delete           Bound     openshift-image-registry/image-registry-storage   standard                 7d22h

There is one PV, with a 100Gi capacity.  It is used for the image
registry.

Now, lets create ``pvc-test`` as specified above::

  ftweedal% oc create -f deploy/pvc-test.yaml
  persistentvolumeclaim/pvc-test created

  ftweedal% oc get pvc pvc-test
  NAME       STATUS    VOLUME    CAPACITY   ACCESS MODES   STORAGECLASS   AGE
  pvc-test   Pending                                       standard       11s

  ftweedal% oc get pv
  NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS    CLAIM                                             STORAGECLASS   REASON    AGE
  pvc-d3bc7c81-8a24-4318-a914-296dbdc5ec3f   100Gi      RWO            Delete           Bound     openshift-image-registry/image-registry-storage   standard                 7d22h

  ftweedal% oc get pvc pvc-test -o yaml |grep storageClassName
  storageClassName: standard

The PVC ``pvc-test`` was created and has status ``pending``.  No new
PV has been created yet.  Finally note that the PVC has
``storageClassName: standard`` (which is the cluster default).

Now lets create a pod that uses ``pvc-test``, mounting it at
``/data``.  The pod spec is:

.. code:: yaml

  apiVersion: v1
  kind: Pod
  metadata:
    name: pod-test
  spec:
    containers:
      - name: pod-test-container
        image: freeipa/freeipa-server:fedora-31
        volumeMounts:
          - mountPath: "/data"
            name: data
        command:
          - sleep
          - "3600"
    volumes:
      - name: data
        persistentVolumeClaim:
          claimName: pvc-test

After creating the pod we will write a file under ``/data``, delete
then re-create the pod, and observe that the file we wrote persists.

::

  ftweedal% oc create -f deploy/pod-test.yaml
  pod/pod-test created

  ftweedal% oc exec pod-test -- sh -c 'echo "hello world" > /data/foo'

  ftweedal% oc delete pod pod-test
  pod "pod-test" deleted

  ftweedal% oc create -f deploy/pod-test.yaml
  pod/pod-test created

  ftweedal% oc exec pod-test -- cat /data/foo
  hello world

  ftweedal% oc delete pod pod-test
  pod "pod-test" deleted

This confirms that the PVC works as intended.  Let's check the
status of the PVC and PVs to see what happened behind the scenes::

  ftweedal% oc get pvc pvc-test
  NAME       STATUS    VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
  pvc-test   Bound     pvc-26d82d50-8e66-4938-bdee-f28ff2bcb49c   10Gi       RWO            standard       16m

  ftweedal% oc get pv
  NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS    CLAIM                                             STORAGECLASS   REASON    AGE
  pvc-26d82d50-8e66-4938-bdee-f28ff2bcb49c   10Gi       RWO            Delete           Bound     ftweedal-operator/pvc-test                        standard                 4m53s
  pvc-d3bc7c81-8a24-4318-a914-296dbdc5ec3f   100Gi      RWO            Delete           Bound     openshift-image-registry/image-registry-storage   standard                 7d23h

Before creating the pod ``pvc-test`` had status ``Pending``.  Now it
is ``Bound`` to the volume
``pvc-26d82d50-8e66-4938-bdee-f28ff2bcb49c`` which was dynamically
provisioned with capacity 10Gi as required by ``pvc-test``.

Finally as we delete ``pvc-test``, observe the automatic deletion of
the dynamically provisioned volume::

  ftweedal% oc delete pvc pvc-test
  persistentvolumeclaim "pvc-test" deleted

  ftweedal% oc get pv
  NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS    CLAIM                                             STORAGECLASS   REASON    AGE
  pvc-d3bc7c81-8a24-4318-a914-296dbdc5ec3f   100Gi      RWO            Delete           Bound     openshift-image-registry/image-registry-storage   standard                 7d23h

``pvc-26d82d50-8e66-4938-bdee-f28ff2bcb49c`` went away, as expected.


Conclusion
----------

As we work toward operationalising FreeIPA in OpenShift, I am
interested in how we can use storage classes to make for a smooth
deployment across different environments and especially those for
which OpenShift Dedicated is available.

I also need to learn more about the best practices or common idioms
for representing in storage classes the application suitability
(e.g. file versus block storage) or performance characteristics of
supported volume types in a cluster.  To make it a bit more
concrete, consider that for performance reasons we might require
low-latency/high-throughput block storage for the 389 DS LDAP
database storage.  How can we express this abstract requirement such
that we get a satisfactory result across a variety of "clouds" with
no administrator effort?  Hopefully storage classes are the answer.
But if they are not the whole solution, from what I have learned so
far I have a strong feeling that they will be a bit part of the
solution.
