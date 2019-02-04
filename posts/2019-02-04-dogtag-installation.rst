How does Dogtag PKI spawn?
==========================

Dogtag PKI is a complex program.  Anyone who has performed a
standalone installation of Dogtag can attest to this (to say nothing
of actually using it).  The program you invoke to install Dogtag is
called ``pkispawn(8)``.  When installing standalone, you invoke
``pkispawn`` directly.  When FreeIPA installs a Dogtag instance, it
invokes ``pkispawn`` behind the scenes.

So what does ``pkispawn`` actually *do*?  In this post I'll explain
how ``pkispawn`` actually spawns a Dogtag instance.  This post is
not intended to be a guide to the many configuration options
``pkispawn`` knows about (although we'll cover several).  Rather,
I'll explain the actions ``pkispawn`` performs (or causes to be
performed) to go from a fresh system to a working Dogtag CA
instance.

This post is aimed at developers and support associates, and to a
lesser extent, people who are trying to diagnose issues themselves
or understand how to accomplish something fancy in their Dogtag
installation.  By explaining the steps involved in spawning a Dogtag
instance, I hope to make it easier for readers to diagnose issues or
implement fixes or enhancements.

``pkispawn`` overview
---------------------

``pkispawn(8)`` is provided by the ``pki-server`` RPM (which is
required by the ``pki-ca`` RPM that provides the CA subsystem).

You can invoke ``pkispawn`` without arguments, and it will prompt
for the minimal data it needs to continue.  These data include the
subsystem to install (e.g. ``CA`` or ``KRA``), and LDAP database
connection details.  For a fresh installation, most defaults are
acceptable.

There are many ways to configure or customise an installation.  A
few important scenarios are:

- installing a ``KRA``, ``OCSP``, ``TKS`` or ``TPS`` subsystem
  associated with the existing ``CA`` subsystem (typically on the
  same machine as the ``CA`` subsystem).

- installing a *clone* of a subsystem (typically on a different
  machine)

- installing a CA subsystem with an externally-signed CA certificate

- non-interactive installation

For the above scenarios, and for many other possible variations, it
is necessary to give ``pkispawn`` a configuration file.  The
``pki_default.cfg(5)`` man page describes the format and available
options.  Some options are relevant to all subsystems, and others
are subsystem-specific (i.e. only for ``CA``, or ``KRA``, etc.)
Here is a basic configuration::

  [DEFAULT]
  pki_server_database_password=Secret.123

  [CA]
  pki_admin_email=caadmin@example.com
  pki_admin_name=caadmin
  pki_admin_nickname=caadmin
  pki_admin_password=Secret.123
  pki_admin_uid=caadmin

  pki_client_database_password=Secret.123
  pki_client_database_purge=False
  pki_client_pkcs12_password=Secret.123

  pki_ds_base_dn=dc=ca,dc=pki,dc=example,dc=com
  pki_ds_database=ca
  pki_ds_password=Secret.123

  pki_security_domain_name=EXAMPLE

  pki_ca_signing_nickname=ca_signing
  pki_ocsp_signing_nickname=ca_ocsp_signing
  pki_audit_signing_nickname=ca_audit_signing
  pki_sslserver_nickname=sslserver
  pki_subsystem_nickname=subsystem

The ``-f`` option tells ``pkispawn`` the configuration file to use.
``-s CA`` tell it install the CA subsystem.

::

  $ pkispawn -f ca.cfg -s CA

For many more examples of how to install Dogtag subsystems for
particular scenarios, see the `PKI 10 Installation guide
<https://www.dogtagpki.org/wiki/PKI_10_Installation>`_ on the Dogtag
wiki.


Terminology
-----------

It is worthwhile to clarify the meaning of some terms:

* ***instance*** or ***installation***.
  An installation of Dogtag on a particular machine.  An instance
  may contain one or more *subsystems*.  There may be more than one
  Dogtag instance on a single machine, although this is uncommon
  (and each instance must use a disjoint set of network ports).
  The default instance name is ``pki-tomcat``.

- ***subsystem***.
  Each main function in Dogtag is provided by a subsystem.  The
  subsystems are: ``CA``, ``KRA``, ``OCSP``, ``TKS`` and ``TPS``.
  Every Dogtag instance must have a ``CA`` subsystem (hence, the
  first subsystem installed must be the ``CA`` subsystem).

- ***clone***.
  For redundancy, a subsystem may be *cloned* to a different
  instance (usually on a different machine; this is not a technical
  requirement but it does not make sense to do otherwise).
  Different subsystems may have different numbers of clones in a
  topology.

- ***topology*** or ***deployment***.
  All of the clones of all subsystems derived from some original CA
  subsystem form a *deployment* or *topology*.  Typically, each
  *instance* in the topology would have a replicated copy of the
  LDAP database.


``pkispawn`` implementation
---------------------------

Two main phases
~~~~~~~~~~~~~~~

``pkispawn`` has two main phases:

1. set up the Tomcat server and Dogtag application

2. send *configuration requests* to the Dogtag application, which
   performs further configuration steps.

(This is not to be confused with a *two step* externally-signed CA
installation.)

Of course there are many more steps than this.  But there is an
important reasons I am making such a high-level distinction:
debugging.  In the first phase ``pkispawn`` does everything.  Any
errors will show up in the ``pkispawn`` log file
(``/var/log/pki/pki-<subsystem>-<timestamp>.log``).  It is usually
straightforward to work out what failed.  *Why* it failed is
sometimes easy to work out, and sometimes not so easy.

But in the second phase, ``pkispawn`` is handing over control to
Dogtag to finish configuring itself.  ``pkispawn`` sends a series of
requests to the ``pki-tomcatd`` web application.  These requests
tell Dogtag to configure things like the database, security domain,
and so on.  If something goes wrong during these steps, you *might*
see something useful in the ``pkispawn`` log, but you will probably
also need to look at the Dogtag ``debug`` log, or even the Tomcat or
Dogtag logs of another subsystem or clone.  I detailed this (in the
context of debugging clone installation failures) in `a previous
post`_.

.. _previous post: 2018-11-30-dogtag-clone-failure-debugging.html


Scriptlets
~~~~~~~~~~

``pkispawn`` is implemented in Python.  The various steps of
installation are implemented as *scriptlets*: small subroutines that
take care of one part of the installation.  These are:

1. ``initialization``: sanity check and normalise installer
   configuration, and sanity check the system environment.

2. ``infrastructure_layout``: create PKI instance directories and
   configuration files.

3. ``instance_layout``: lay out the Tomcat instance and
   configuration files (skipped when spawning a second subsystem on
   an existing instance).

4. ``subsystem_layout``: lay out subsystem-specific files and
   directories.

5. ``webapp_deployment``: deploy the Tomcat web application.

6. ``security_databases``: set up the main Dogtag NSS database, and a
   client database where the administrator key and certificate will
   be created.

7. ``selinux_setup``: establish correct SELinux contexts on instance
   and subsystem files.

8. ``keygen``: generate keys and CSRs for the subsystem (for the CA
   subsystem, this inclues the CA signing key and CSR for external
   signing).

9. ``configuration``: For external CA installation, import the
   externally-signed CA certificate and chain.  (Re)start the
   ``pki-tomcatd`` instance and send configuration requests to the
   Java application.  The whole second phase discussed in the
   previous section occurs here.  It will be discussed in more
   detail in the next section.

10. ``finalization``: enable PKI to start on boot (by default) and
    optionally purge client NSS databases that were set up during
    installation.

For a two-step externally-signed CA installation, the
``configuration`` and ``finalization`` scriptlets are skipped during
step 1, and in step 2 the scriptlets up to and including ``keygen``
are skipped.  (A bit of hand-waving here; they not not really
skipped but return early).

In the codebase, scriptlets are located under
``base/server/python/pki/server/deployment/scriptlets/<name>.py``.
The list of scriptlets and the order in which they're run is given
by the ``spawn_scriplets`` variable in
``base/server/etc/default.cfg``.  Note that *``scriplet``* there is
not a typo.  Or maybe it is, but it's not *my* typo.  In some parts
of the codebase, we say *scriplet*, and in others it's *scriptlet*.
This is mildly annoying, but you just have to be careful to use the
correct class or variable name.

Some other Python files contain a lot of code used during
deployment.  It's not reasonable to make an exhaustive list, but
``pki.server.deployment.pkihelper`` and
``pki.server.deployment.pkiparser`` in particular include a lot of
configuration processing code.  If you are implementing or changing
``pkispawn`` configuration options, you'll be defining them and
following changes around in these files (and possibly others), as
well as in ``base/server/etc/default.cfg``.


Scriptlets and uninstallation
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The installation scriptlets also implement corresponding
uninstallation behaviours.  When uninstalling a Dogtag instance or
subsystem via the ``pkidestroy`` command, each scriptlets'
uninstallation behaviour is invoked.  The order in which they're
invoked is different from installation, and is given by the
``destroy_scriplets`` variable in ``base/server/etc/default.cfg``.

Configuration requests
~~~~~~~~~~~~~~~~~~~~~~

The ``configuration`` scriptlet sends a series of configuration
requests to the Dogtag web API.  Each request causes Dogtag to
perform specific configuration behaviour(s).  Depending on the
subsystem being installed and whether it is a clone, these steps may
including communication with other subsystems or instances, and/or
the LDAP database.

The requests performed, in order, are:

1. ``/rest/installer/configure``: configure (but don't yet create)
   the security domain.  Import and verify certificates.  If
   creating a clone, request number range allocations from the
   master.

2. ``/rest/installer/setupDatabase``: add database connection
   configuration to ``CS.cfg``.  Enable required DS plugins.
   Populate the database.  If creating a clone, initialise
   replication (this can be suppressed if replication is managed
   externally, as is the case for FreeIPA in Domain Level 1).
   Populate VLV indices.

3. ``/rest/installer/configureCerts``: configure system
   certificates, generating keys and issuing certificates where
   necessary.

4. ``/rest/installer/setupAdmin`` (skipped for clones): create admin
   user and issue certificate.

5. ``/rest/installer/backupKeys`` (optional): back up system
   certificates and keys to a PKCS #12 file.

6. ``/rest/installer/setupSecurityDomain``: create the security
   domain data in LDAP (non-clone) or add the new clone to the
   security domain.

7. ``/rest/installer/setupDatabaseUser``: set up the LDAP database
   user, including certificate (if configured).  This is the user
   that Dogtag uses to bind to LDAP.

8. ``/rest/installer/finalizeConfiguration``: remove *preop*
   configuration entries (which are only used during installation)
   and perform other finalisation in ``CS.cfg``.

For all of these requests, the ``configuration`` scriptlet builds
the request data according to the ``pkispawn`` configuration.  Then
it sends the request to the current hostname.  Communications
between ``pkispawn`` and Tomcat are unlikely to fail (connection
failure would suggest a major network configuration problem).

If something goes wrong during processing of the request, errors
should appear in the subsystem debug log
(``/etc/pki/pki-tomcat/ca/debug.YYYY-MM-DD.log``;
``/etc/pki/pki-tomcat/ca/debug`` on older versions), or the system
journal.  If the local system had to contact other subsystems or
instances on other hosts, it may be necessary to look at the debug
logs, system journal or Tomcat / Apache httpd logs of the relevant
host / subsystem.  I wrote about this at length in `a previous
post`_ so I won't say more about it here.

In terms of the code, the resource paths and servlet interface are
defined in ``com.netscape.certsrv.system.SystemConfigResource``.
The implementation is in
``com.netscape.certsrv.system.SystemConfigService``, with a
considerable amount of behaviour residing as helper methods in
``com.netscape.cms.servlet.csadmin.ConfigurationUtils``.  If you are
investigating or fixing configuration request failures, you will
spend a fair bit of time grubbing around in these classes.

Conclusion
----------

As I have shown in this post, spawning a Dogtag PKI instance
involves a lot of steps.  There are many, *many* ways to customise
the installation and I have glossed over many details.  But my aim
in this post was not to be a comprehensive reference guide or
how-to.  Rather the intent was to give a high-level view of what
happens during installation, and how those behaviours are
implemented.  Hopefully I have achieved that, and as a result you
are now able to more easily diagnose issues or implement changes or
features in the Dogtag installer.
