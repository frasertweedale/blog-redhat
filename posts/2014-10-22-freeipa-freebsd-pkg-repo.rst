---
tags: freeipa, freebsd, sysadmin
---

Configuring FreeBSD as a FreeIPA client
=======================================

A recent thread on the *freeipa-users* mailing list `highlighted one
user's experience`_ with setting up FreeBSD_ as a FreeIPA_ client,
complete with SSSD and Sudo integration.  GNU+Linux systems have
``ipa-client-install``, but the lack of an equivalent on FreeBSD
means that much of the configuration must be done manually.  There
is a lot of room for error, and this user encountered several
"gotchas" and caveats.

Services that require manual configuration include PAM, NSS,
Kerberos and SSSD.  Certain features may require even more services
to be configured, such as ``sshd``, for ``known_hosts`` management.
Most of the steps have been `outlined in a post`_ on the FreeBSD
forums.

.. _Highlighted one user's experience: https://www.redhat.com/archives/freeipa-users/2014-October/msg00153.html
.. _FreeBSD: https://www.freebsd.org/
.. _FreeIPA: http://www.freeipa.org/page/Main_Page
.. _outlined in a post: https://forums.freebsd.org/threads/freebsd-freeipa-via-sssd.46526/

But before one can even begin configuring all these services, SSSD,
Sudo and related software and dependencies must be installed.
Unfortunately, as also outlined in the forum post, non-default port
options and a certain ``make.conf`` variable must be set in order to
build the software such that the system can be used as a FreeIPA
client. Similarly, the official binary package repositories do not
provide the packages in a suitable configuration.

This post details how I built a custom binary package repository for
FreeBSD and how administrators can use it to install exactly the
right packages needed to operate as a FreeIPA client.  Not all
FreeBSD administrators will want to take this path, but those who do
will not have to worry about getting the ports built correctly, and
will save some time since the packages come pre-built.


Custom package repository
-------------------------

poudriere_ is a tool for creating binary package repositories
compatible with FreeBSD's next-generation ``pkg(8)`` package manager
(also known as "pkgng".)  The official package repositories are
built using poudriere, but anyone can use it to build their own
package repositories.  Repositories are built in isolated *jails*
(an OS-level virtualisation technology similar to LXC or Docker) and
can build packages from a list of ports (or the entire ports tree)
with customised options.  A customised ``make.conf`` file can also
be supplied for each jail.

Providing a custom repository with FreeIPA-compatible packages is a
practical way to help people wanting to use FreeBSD with FreeIPA.
It means fewer steps in preparing a system as a FreeIPA client
(fewer opportunities to make mistakes), and also saves a substantial
amount of time since the administrator doesn't need to build any
ports.  The `BSD Now`_ podcast has a detailed `poudriere tutorial`_;
all the detail on how to use poudriere is included there, so I will
just list the FreeIPA-specific configuration for the FreeIPA
repository:

- ``security/sudo`` is built with the ``SSSD`` option set
- ``WANT_OPENLDAP_SASL=yes`` appears in the jail's ``make.conf``

.. _poudriere: https://github.com/freebsd/poudriere
.. _BSD Now: http://www.bsdnow.tv/
.. _poudriere tutorial: http://www.bsdnow.tv/tutorials/poudriere

The repository is currently being built for FreeBSD 10.0 (both amd64
and i386.) 10.1 is not far away; once it is released I will build it
for 10.1 instead.  If anyone out there would like it built for
FreeBSD 9.3 I can do that too - just let me know!

Assuming the custom repository is available for the release and
architecture of the FreeBSD system, the following script will enable
the repository and install the required packages.

::

  #!/bin/sh
  pkg install -y ca_root_nss
  ln -s /usr/local/share/certs/ca-root-nss.crt /etc/ssl/cert.pem
  mkdir -p /usr/local/etc/pkg/repos
  cat >/usr/local/etc/pkg/repos/FreeIPA.conf <<"EOF"
  FreeIPA: {
    url: "https://frase.id.au/pkg/${ABI}_FreeIPA",
    signature_type: "pubkey",
    pubkey: "/usr/share/keys/pkg/FreeIPA.pem",
    enabled: yes
  }
  EOF
  cat >/usr/share/keys/pkg/FreeIPA.pem <<EOF
  -----BEGIN PUBLIC KEY-----
  MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAopt0Lubb0ur+L+VzsP9k
  i4QrvQb/4gVlmr/d59lUsTr9cz5B5OtNLi+WMVcNh4EmmNIiWoVuQY4Wqjm2d1IA
  VCXw+OqeAuj9nUW4jSvI/lDLyErFBXezNM5yggeesiV2ii+uO41zOjUxnSkupFzh
  zOWr+Oj4kJI/iNU++3RpzyrBSmSGK9TN9k3afhyDMNlJi5SqK/wOrSjqAMfaufHE
  MkJqBibDL/+xx48SbtInhtD4LIneHoOGxVtkLIcTSS5EpnIsDWZgXX6jBatv9LJe
  u2UeQsKLKcCgrhT3VX+pc/aDsUFS4ZqOonLRt9mcFVxC4NDNMKsfXTCd760HQXYU
  enVLydNavvGtGYQpbUWx5IT3IphaNxWANACpWrcvTawgPyGkGTPd347Nqhm5YV2c
  YRf4rVX/S7U0QOzMPxHKN4siZVCspiedY+O4P6qe2R2cTyxntjLVGZcTBlXAdQJ8
  UfQuuX97FX47xghxR6wyWfkXGCes2kVdVo0fF0vkYe1652SGJsfWjc5ojR9KFKkD
  DN3x3Wu6kW0koZMF3Tf0rtSLDmbZEBddIPFrXo8QHiyqFtU3DLrYWGmbLRkYKnYR
  KvG3XCJ6EmvMlfr8GjDIaEiGo7E7IyLusZXXzbIW2EKQdwa6p4N8wrW/30Ov53jp
  rO+Bwn10+9DZTupQ3c04lsUCAwEAAQ==
  -----END PUBLIC KEY-----
  EOF
  pkg update
  pkg install -r FreeIPA -y cyrus-sasl-gssapi sssd sudo

Once the packages are installed from the custom repository,
configuration can continue as indicated in the forum post.


Future efforts
--------------

This post was concerned with package installation.  This is an
important but relatively small part of setting up a FreeBSD client.
There is more that can be done to make it easier to integrate
FreeBSD (and other non-GNU+Linux systems) with FreeIPA.  I will
conclude this post with some ideas along this trajectory.

Recent versions of FreeIPA include the ``ipa-advise`` tool, which
explains how various legacy systems can be configured to some extent
as FreeIPA clients.  ``ipa-advise config-freebsd-nss-pam-ldapd``
shows advice on how to configure a FreeBSD system, but the
information is out of date in many respects - it references the old
binary package tools (which have now been completely removed) and
has no information about SSSD.  This information should be updated.
I have had this task on a sticky-note for a little while now, but if
someone else beats me to it, that would be no bad thing.

The latest major version of SSSD is 1.12, but the FreeBSD port is
back at 1.9.  The 1.9 release is a *long-term maintenance* (LTM)
release, but any efforts to bring 1.12 to FreeBSD *alongside* 1.9
would undoubtedly be appreciated by the port maintainer and users.

A longer term goal should be a port of (or an equivalent to)
``ipa-client-install`` for FreeBSD.  Most of the software needed for
FreeIPA integration on FreeBSD is similar or identical to that used
on GNU+Linux, but there are some differences.  It would be a time
consuming task - lots of trial runs and testing - but probably not
particularly difficult.

In regards to the package repository, `work is underway`_ to add
`support for package "flavours"`_ to the FreeBSD packaging
infrastructure.  When this feature is ready, a small effort should
be undertaken to add a FreeIPA flavour to the ports tree, and ensure
that the resultant packages are made available in the official
package repository.  Once this is achieved, neither manual port
builds nor the custom package repository will be required - \
everything needed to configure FreeBSD as a FreeIPA client will be
available to all FreeBSD users by default.

.. _work is underway: http://blogs.freebsdish.org/portmgr/2014/09/01/the-ports-tree-is-now-stage-only/
.. _support for package "flavours": http://lists.freebsd.org/pipermail/freebsd-pkg/2014-September/000703.html
