Docker build context and symbolic links
=======================================

Docker_ is an application container system for Linux.  Under the
hood it's like FreeBSD *jails*, but on top of that it provides
powerful *image* specification and indexing capabilities.  Images
are built up in *layers*; each image depends on some other image
(down to a *base image*), so a particular image might be a small
delta on some shared dependency.

.. _Docker: https://www.docker.io/

In investigating ways to *Dockerize* FreeIPA, particularly for ease
of sharing development builds, it makes sense to base builds on an
image that contains all the build dependencies.  Since the
dependencies are the same for any build, they can be made available
in a single image to shave down the build time and reduce the size
of the final images.

So there will be one ``Dockerfile`` for the builddeps image.  But we
will need another ``Dockerfile`` for the build itself, which will
depend on the builddeps image.  Each ``Dockerfile`` must reside in
its own directory - there is no facility for specifying a different
filename, e.g. ``Dockerfile.builddep`` - yet each ``Dockerfile``
needs to access some files in the root of the repository, e.g.
``freeipa.spec.in``.

My initial approach is to have the builddep ``Dockerfile`` live in
the repository at ``docker/freeipa-builddep/Dockerfile``.  The file
consists of *instructions* specifying the image to build the new
image ``FROM``, files to ``ADD`` into the image, and commands to
``RUN``.  The initial ``Dockerfile`` is::

  FROM fedora:20
  ADD ../../freeipa.spec.in freeipa.spec.in
  RUN cp freeipa.spec.in freeipa-builddep.spec
  RUN yum-builddep freeipa-builddep.spec

Let's attempt to build the image::

  % sudo docker build .
  Uploading context 3.072 kB
  Uploading context
  Step 0 : FROM fedora:20
   ---> b7de3133ff98
  Step 1 : ADD ../../freeipa.spec.in freeipa.spec.in
  2014/05/19 16:34:21 ../../freeipa.spec.in: no such file or directory

The *context* of a build is the contents of the directory containing
the ``Dockerfile``.  Attempting to reference files outside the
context fails.  The ``ADD`` instruction documentation_ does kindly
mention this.

.. _documentation: http://docs.docker.io/reference/builder/#add

We certainly don't want multiple copies of ``freeipa.spec.in``
floating around, so perhaps we can use a symbolic link.  The
``Dockerfile`` now reads::

  FROM fedora:20
  ADD freeipa.spec.in freeipa.spec.in
  RUN cp freeipa.spec.in freeipa-builddep.spec
  RUN yum-builddep freeipa-builddep.spec

Creating the symlink and trying the build again::

  % cd docker/freeipa-builddep/
  % ln -s ../../freeipa.spec.in
  % docker build .
  Uploading context 3.072 kB
  Uploading context
  Step 0 : FROM fedora:20
   ---> b7de3133ff98
  Step 1 : ADD freeipa.spec.in freeipa.spec.in
  2014/05/19 16:45:06 freeipa.spec.in: no such file or directory

Docker really does not like symlinks.

I'm not sure how to proceed from here, and will be seeking feedback
from the other FreeIPA developers since the other options are either
intrusive (different ``Dockerfile`` = different branch) or hacky
(e.g. pulling things in from URLs, or multiple copies of spec file
in repository).  Perhaps I am overlooking a nice solution, or
perhaps one will come about soon given that Docker is still under
heavy development.

Stay tuned.
