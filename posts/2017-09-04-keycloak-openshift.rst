---
tags: containers, idm, openshift
---

Running Keycloak in OpenShift
=============================

At PyCon Australia in August I gave a presentation about federated
and social identity.  I demonstrated concepts using `Keycloak`_, an
Open Source, feature rich *identity broker*.  Keycloak is deployed
in JBoss, so I wasn't excited about the prospect of setting up
Keycloak from scratch.  Fortunately there is an `official Docker
image`_ for Keycloak, so with that as the starting point I took an
opportunity to finally learn about OpenShift v3, too.

This post is simply a recounting of how I ran Keycloak on OpenShift.
Along the way we will look at how to get the containerised Keycloak
to trust a private certificate authority (CA).

One thing that is not discussed is how to get Keycloak to persist
configuration and user records to a database.  This was not required
for my demo, but it will be important in a production deployment.
Nevertheless I hope this article is a useful starting point for
someone wishing to deploy Keycloak on OpenShift.

.. _Keycloak: http://www.keycloak.org/
.. _official Docker image: https://hub.docker.com/r/jboss/keycloak/


Bringing up a local OpenShift cluster
-------------------------------------

To deploy Keycloak on OpenShift, one must first have an OpenShift.
`OpenShift Online`_ is Red Hat's public PaaS offering.  Although
running the demo on a public PaaS was my first choice, OpenShift
Online was experiencing issues at the time I was setting up my demo.
So I sought a local solution.  This approach would have the
additional benefit of not being subject to the whims of conference
networks (or, it was supposed to - but that is a story for another
day!)

.. _Openshift Online: https://www.openshift.com/

``oc cluster up``
^^^^^^^^^^^^^^^^^

Next I tried ``oc cluster up``.  ``oc`` is the official OpenShift
client program.  On Fedora, it is provided by the ``origin-clients``
package.  ``oc cluster up`` command pulls required images and brings
up an OpenShift cluster running on the system's Docker
infrastructure.  The command takes no further arguments; it really
is that simple!  Or is it...?

::

  % oc cluster up
  -- Checking OpenShift client ... OK
  -- Checking Docker client ... OK
  -- Checking Docker version ... OK
  -- Checking for existing OpenShift container ... OK
  -- Checking for openshift/origin:v1.5.0 image ...
     Pulling image openshift/origin:v1.5.0
     Pulled 0/3 layers, 3% complete
     ...
     Pulled 3/3 layers, 100% complete
     Extracting
     Image pull complete
  -- Checking Docker daemon configuration ... FAIL
     Error: did not detect an --insecure-registry argument on the Docker daemon
     Solution:

       Ensure that the Docker daemon is running with the following argument:
          --insecure-registry 172.30.0.0/16

OK, so it is not that simple.  But it got a fair way along, and
(kudos to the OpenShift developers) they have provided actionable
feedback about how to resolve the issue.  I added
``--insecure-registry 172.30.0.0/16`` to the ``OPTIONS`` variable in
``/etc/sysconfig/docker``, then restarted Docker and tried again::

  % oc cluster up
  -- Checking OpenShift client ... OK
  -- Checking Docker client ... OK
  -- Checking Docker version ... OK
  -- Checking for existing OpenShift container ... OK
  -- Checking for openshift/origin:v1.5.0 image ... OK
  -- Checking Docker daemon configuration ... OK
  -- Checking for available ports ... OK
  -- Checking type of volume mount ...
     Using nsenter mounter for OpenShift volumes
  -- Creating host directories ... OK
  -- Finding server IP ...
     Using 192.168.0.160 as the server IP
  -- Starting OpenShift container ...
     Creating initial OpenShift configuration
     Starting OpenShift using container 'origin'
     Waiting for API server to start listening
  -- Adding default OAuthClient redirect URIs ... OK
  -- Installing registry ... OK
  -- Installing router ... OK
  -- Importing image streams ... OK
  -- Importing templates ... OK
  -- Login to server ... OK
  -- Creating initial project "myproject" ... OK
  -- Removing temporary directory ... OK
  -- Checking container networking ... OK
  -- Server Information ... 
     OpenShift server started.
     The server is accessible via web console at:
         https://192.168.0.160:8443

     You are logged in as:
         User:     developer
         Password: developer

     To login as administrator:
         oc login -u system:admin

Success!  Unfortunately, on my machine with several virtual network,
``oc cluster up`` messed a bit too much with the routing tables, and
when I deployed Keycloak on this cluster it was unable to
communicate with my VMs.  No doubt these issues could have been
solved, but being short on time and with other approaches to try, I
abandoned this approach.


*Minishift*
^^^^^^^^^^^

`Minishift`_ is a tool that launches a single-node OpenShift cluster
in a VM.  It supports a variety of operating systems and
hypervisors.  On GNU+Linux it supports KVM and VirtualBox.

.. _Minishift: https://www.openshift.org/minishift/

First install `docker-machine`_ and `docker-machine-driver-kvm`_.
(follow the instructions at the preceding links).  Unfortunately
these are not yet packaged for Fedora.

.. _docker-machine: https://github.com/docker/machine/releases
.. _docker-machine-driver-kvm: https://github.com/dhiltgen/docker-machine-kvm/releases

Download and extract the Minishift release for your OS from
https://github.com/minishift/minishift/releases.

Run ``minishift start``::

  % ./minishift start
  -- Installing default add-ons ... OK
  Starting local OpenShift cluster using 'kvm' hypervisor...
  Downloading ISO 'https://github.com/minishift/minishift-b2d-iso/releases/download/v1.0.2/minishift-b2d.iso'

  ... wait a while ...

It downloads a `*boot2docker*`_ VM image containing the openshift
cluster, boots the VM, and the console output then resembles the
output of ``oc cluster up``.  I deduce that ``oc cluster up`` is
being executed on the VM.

.. _*boot2docker*: http://boot2docker.io/

At this point, we're ready to go.  Before I continue, it is
important to note that once you have access to an OpenShift cluster,
the user experience of creating and managing applications is
essentially the same.  The commands in the following sections are
relevant, regardless whether you are running your app on OpenShift
online, on a cluster running on your workstation, or anything in
between.


Preparing the Keycloak image
----------------------------

The JBoss project provides official Docker images, including an
`official Docker image`_ for Keycloak.  This image runs fine in
plain Docker but the directory permissions are not correct for
running in OpenShift.

The ``Dockerfile`` for this image is found in the
`*jboss-dockerfiles/keycloak* repository`_ on GitHub.  Although they
do not publish an official image for it, this repository also
contains a ``Dockerfile`` for Keycloak on OpenShift!  I was able to
build that image myself and upload it to `my *Docker Hub* account`_.
The steps were as follows.

.. _*jboss-dockerfiles/keycloak* repository: https://github.com/jboss-dockerfiles/keycloak
.. _my *Docker Hub* account: https://hub.docker.com/r/frasertweedale/keycloak-openshift/

First clone the ``jboss-dockerfiles`` repo::

  % git clone https://github.com/jboss-dockerfiles/keycloak docker-keycloak
  Cloning into 'docker-keycloak'...
  remote: Counting objects: 1132, done.
  remote: Compressing objects: 100% (22/22), done.
  remote: Total 1132 (delta 14), reused 17 (delta 8), pack-reused 1102
  Receiving objects: 100% (1132/1132), 823.50 KiB | 158.00 KiB/s, done.
  Resolving deltas: 100% (551/551), done.
  Checking connectivity... done.

Next build the Docker image for OpenShift::

  % docker build docker-keycloak/server-openshift
  Sending build context to Docker daemon 2.048 kB
  Step 1 : FROM jboss/keycloak:latest
   ---> fb3fc6a18e16
  Step 2 : USER root
   ---> Running in 21b672e19722
   ---> eea91ef53702
  Removing intermediate container 21b672e19722
  Step 3 : RUN chown -R jboss:0 $JBOSS_HOME/standalone &&     chmod -R g+rw $JBOSS_HOME/standalone
   ---> Running in 93b7d11f89af
   ---> 910dc6c4a961
  Removing intermediate container 93b7d11f89af
  Step 4 : USER jboss
   ---> Running in 8b8ccba42f2a
   ---> c21eed109d12
  Removing intermediate container 8b8ccba42f2a
  Successfully built c21eed109d12

Finally, tag the image into the repo and push it::

  % docker tag c21eed109d12 registry.hub.docker.com/frasertweedale/keycloak-openshift

  % docker login -u frasertweedale registry.hub.docker.com
  Password:
  Login Succeeded

  % docker push registry.hub.docker.com/frasertweedale/keycloak-openshift
  ... wait for upload ...
  latest: digest: sha256:c82c3cc8e3edc05cfd1dae044c5687dc7ebd9a51aefb86a4bb1a3ebee16f341c size: 2623


Adding CA trust
^^^^^^^^^^^^^^^

For my demo, I used a local FreeIPA installation to issue TLS
certificates for the the Keycloak app.  I was also going to carry
out a scenario where I configure Keycloak to use that FreeIPA
installation's LDAP server to authenticate users.  I wanted to use
TLS everywhere (eat your own dog food!) I needed the Keycloak
application to trust the CA of one of my local FreeIPA
installations.  This made it necessary to build another Docker image
based on the ``keycloak-openshift`` image, with the appropriate CA
trust built in.

The content of the ``Dockerfile`` is::

  FROM frasertweedale/keycloak-openshift:latest
  USER root
  COPY ca.pem /etc/pki/ca-trust/source/anchors/ca.pem
  RUN update-ca-trust
  USER jboss

The file ``ca.pem`` contains the CA certificate to add.  It must be
in the same directory as the ``Dockerfile``.  The build copies the
CA certificate to the appropriate location and executes
``update-ca-trust`` to ensure that applications - including Java
programs - will trust the CA.

Following the ``docker build`` I tagged the new image into my
``hub.docker.com`` repository (tag: ``f25-ca``) and pushed it.  And
with that, we are ready to deploy Keycloak on OpenShift.


Creating the Keycloak application in OpenShift
----------------------------------------------

At this point we have a local OpenShift cluster (via *Minishift*)
and a Keycloak image (``frasertweedale/keycloak-openshift:f25-ca``)
to deploy.  When deploying the app we need to set some environment
variables:

``KEYCLOAK_USER=admin``
  A username for the Keycloak admin account to be created
``KEYCLOAK_PASSWORD=secret123``
  Passphrase for the admin user
``PROXY_ADDRESS_FORWARDING=true``
  Because the application will be running behind OpenShift's HTTP
  proxy, we need to tell Keycloak to use the "external" hostname
  when creating hyperlinks, rather than Keycloak's own view.

Use the ``oc new-app`` command to create and deploy the
application::

  % oc new-app --docker-image frasertweedale/keycloak-openshift:f25-ca \
      --env KEYCLOAK_USER=admin \
      --env KEYCLOAK_PASSWORD=secret123 \
      --env PROXY_ADDRESS_FORWARDING=true
  --> Found Docker image 45e296f (4 weeks old) from Docker Hub for "frasertweedale/keycloak-openshift:f25-ca"

      * An image stream will be created as "keycloak-openshift:f25-ca" that will track this image
      * This image will be deployed in deployment config "keycloak-openshift"
      * Port 8080/tcp will be load balanced by service "keycloak-openshift"
        * Other containers can access this service through the hostname "keycloak-openshift"

  --> Creating resources ...
      imagestream "keycloak-openshift" created
      deploymentconfig "keycloak-openshift" created
      service "keycloak-openshift" created
  --> Success
      Run 'oc status' to view your app.

The app gets created immediately but it is not ready yet.  The
download of the image and deployment of the container (or *pod* in
OpenShift / Kubernetes terminology) will proceed in the background.

After a little while (depending on how long it takes to download the
~300MB Docker image) ``oc status`` will show that the deployment is
up and running::

  % oc status
  In project My Project (myproject) on server https://192.168.42.214:8443

  svc/keycloak-openshift - 172.30.198.217:8080
    dc/keycloak-openshift deploys istag/keycloak-openshift:f25-ca 
      deployment #2 deployed 3 minutes ago - 1 pod

  View details with 'oc describe <resource>/<name>' or list everything with 'oc get all'.

(In my case, the first deployment failed because the 10-minute
timeout elapsed before the image download completed; hence
``deployment #2`` in the output above.)


Creating a secure route
^^^^^^^^^^^^^^^^^^^^^^^

Now the Keycloak application is running, but we cannot reach it from
outside the Keycloak project itself.  In order to be able to reach
it there must be a *route*.  The ``oc create route`` command lets us
create a route that uses TLS (so clients can authenticate the
service).  We will use the domain name ``keycloak.ipa.local``.  The
public/private keypair and certificate have already been generated
(how to do that is outside the scope of this article).  The
certificate was signed by the CA we added to the image earlier.  The
service name - visible in the ``oc status`` output above - is
``svc/keycloak-openshift``.

::

  % oc create route edge \
    --service svc/keycloak-openshift \
    --hostname keycloak.ipa.local \
    --key /home/ftweedal/scratch/keycloak.ipa.local.key \
    --cert /home/ftweedal/scratch/keycloak.ipa.local.pem
  route "keycloak-openshift" created


Assuming there is a DNS entry pointing ``keycloak.ipa.local`` to the
OpenShift cluster, and that the system trusts the CA that issued the
certificate, we can now visit our Keycloak application::

  % curl https://keycloak.ipa.local/
  <!--
    ~ Copyright 2016 Red Hat, Inc. and/or its affiliates
    ~ and other contributors as indicated by the @author tags.
    ~
    ~ Licensed under the Apache License, Version 2.0 (the "License");
    ~ you may not use this file except in compliance with the License.
    ~ You may obtain a copy of the License at
    ~
    ~ http://www.apache.org/licenses/LICENSE-2.0
    ~
    ~ Unless required by applicable law or agreed to in writing, software
    ~ distributed under the License is distributed on an "AS IS" BASIS,
    ~ WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    ~ See the License for the specific language governing permissions and
    ~ limitations under the License.
    -->
  <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">

  <html>
  <head>
      <meta http-equiv="refresh" content="0; url=/auth/" />
      <meta name="robots" content="noindex, nofollow">
      <script type="text/javascript">
          window.location.href = "/auth/"
      </script>
  </head>
  <body>
      If you are not redirected automatically, follow this <a href='/auth'>link</a>.
  </body>
  </html>

If you visit in a browser, you will be able to log in using the
admin account credentials specified in the ``KEYCLOAK_USER`` and
``KEYCLOAK_PASSWORD`` environment variables specified when the app
was created.  And from there you can create and manage
authentication realms, but that is beyond the scope of this article.


Conclusion
----------

In this post I discussed how to run Keycloak in OpenShift, from
bringing up an OpenShift cluster to building the Docker image and
creating the application and route in OpenShift.  I recounted that I
found *OpenShift Online* unstable at the time I tried it, and that
although ``oc cluster up`` did successfully bring up a cluster I had
trouble getting the Docker and VM networks to talk to each other.
Eventually I tried *Minishift* which worked well.

We saw that although there is no official Docker image for Keycloak
in OpenShift, there is a ``Dockerfile`` that builds a working image.
It is easy to further extend the image to add trust for private CAs.

Creating the Keycloak app in OpenShift, and adding the routes, is
straightforward.  There are a few important environment variables
that must be set.  The ``oc create route`` command was used to
create a secure route to access the application from the outside.

We did not discuss how to set up Keycloak with a database for
persisting configuration and user records.  The deployment we
created is ephemeral.  This satisfied my needs for demonstration
purposes but production deployments will require persistence.  There
are official JBoss Docker images that extend the base Keycloak image
and add `support for PostgreSQL`_, `MySQL`_ and `MongoDB`_.  I have
not tried these but I'd suggest starting with one of these images if
you are looking to do a production deployment.  Keep in mind that
these images may not include the changes that are required for
deploying in OpenShift.

.. _support for PostgreSQL: https://hub.docker.com/r/jboss/keycloak-postgres/
.. _MySQL: https://hub.docker.com/r/jboss/keycloak-mysql/
.. _MongoDB: https://hub.docker.com/r/jboss/keycloak-mongo/
