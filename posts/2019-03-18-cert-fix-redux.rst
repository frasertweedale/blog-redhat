---
tags: dogtag, renewal, troubleshooting, freeipa
---

``cert-fix`` redux
==================

`A few weeks ago I analysed`_ the Dogtag ``pki-server cert-fix``
tool, which is intended to assist with recovery in scenarios where
expired certificates inhibit Dogtag's normal operation.
Unfortunately, there were some flawed assumptions and feature gaps
that limited the usefulness of the tool, especially in FreeIPA
contexts.

In this post, I provide an update on changes that are being made to
the tool to address those shortcomings.

.. _A few weeks ago I analysed: 2019-02-28-dogtag-cert-fix.html

Recap
-----

Recapping the shortcomings in brief:

1. When TLS client certificate authentication is used to
   authenticate to Dogtag (the default for FreeIPA), and expired
   ``subsystem`` certificate causes authentication failure and
   Dogtag cannot start.

2. When Dogtag is configured to use TLS or STARTTLS when connecting
   to the database, an expired LDAP service certificate causes
   connection failure.

3. ``cert-fix`` uses an admin or agent certificate to perform
   authenticated operations against Dogtag.  An expired certificate
   causes authentication failure, and certificate renewal fails.

4. Expired CA certificate is not handled.  Due to longer validity
   periods, and externally-signed CA certificates expiring at
   different times from Dogtag system certificates, this scenario is
   less common, but it still occurs.

5. The need to renew non-system certificates.  Apart from system
   certificates, in order for correct operation of Dogtag it may be
   necessary to renew some other certificates, such as an expired
   LDAP service certificate, or an expired agent certificate (e.g.
   ``IPA RA``).  ``cert-fix`` did not provide a way to do this.


Resolving the LDAP-related issues (issues #1 and #2)
----------------------------------------------------

``cert-fix`` now switches the deployment to use password
authentication to LDAP, over an insecure connection on port 389.
The original database configuration is restored when ``cert-fix``
finishes.

The ``subsystem`` certificate is used by Dogtag to authenticate to
LDAP.  Switching to password authentication works around the expired
``subsystem`` certificate.  Furthermore if the ``subsystem``
certificate gets renewed, the new certificate gets imported into the
``pkidbuser`` LDAP entry so that authentication will work (389 DS
requires an exact certificate match in the ``userCertificate``
attribute of the user).

If the LDAP service certificate is expired, this procedure works
around that but *does not renew it*.  This is problem #3, and is
addressed separately.

Switching Dogtag to password authentication to LDAP means resetting
the ``pkidbuser`` account password.  We use the ``ldappasswd``
program to do this.  The LDAP *password modify* extended operation
requires confientiality (i.e. TLS or STARTTLS); an expired LDAP
service certificate inhibits this.  Therefore we use LDAPI and
autobind.  The LDAPI socket is specified via the ``--ldapi-socket``
option.

FreeIPA always configures LDAP and ``root`` autobind to the
``cn=Directory Manager`` LDAP account.  For standalone Dogtag
installations these may need to be configured before runnning
``cert-fix``.


Resolving expired agent certificate (issue #3)
----------------------------------------------

Instead of using the certificate to authenticate the agent, reset
the password of the agent account and use that password to
authenticate the agent.  The password is randomly generated and
forgotten after ``cert-fix`` terminates.

The agent account to use is now specified via the ``--agent-uid``
option.  NSSDB-related options for specifying the agent certificate
and NSSDB passphrase have been removed.


Renewing other certificates (issue #5)
--------------------------------------

``cert-fix`` learned the ``--extra-cert`` option, which gives the
serial number of an extra certificate to renew.  The option can be
given multiple times to specify multiple certificates.  Each
certificate gets renewed and output in
``/etc/pki/<instance-dir>/certs/<serial>-renewed.crt``.  If a
non-existing serial number is specified, an error is printed but
processing continues.

This facility allows operators (or wrapper tools) to renew other
essential certificates alongside the Dogtag system certificates.
Further actions are needed to put those new certificates in the
right places.  But it is fair, in order to keep to keep the
``cert-fix`` tool simple, to put this burden back on the operator.
In any case, we intend to write a supplementary tool for FreeIPA
that wraps ``cert-fix`` and takes care of working out which extra
certificates to renew, and putting them in the right places.


New or changed assumptions
--------------------------

The changes dicsussed above abolish some assumptions that were
previously made by ``cert-fix``, and establish some new assumptions.

Absolished:

- A valid admin certificate is no longer needed

- A valid LDAP service certificate is no longer needed

- When Dogtag is configured to use certificate authentication to
  LDAP, a valid subsystem certificate is no longer needed

New:

- ``cert-fix`` must be run as ``root``.

- LDAPI must be configured, with ``root`` autobinding to
  ``cn=Directory Manager`` or other account with privileges on
  ``o=ipaca`` subtree, including password reset privileges.

- The password of the specified agent account will be reset.
  If needed, it can be changed back afterwards (manually; successful
  execution of ``cert-fix`` proves that the operator has privileges
  to do this).

- If Dogtag was configured to use TLS certificate authentication to
  bind to LDAP, the password on the ``pkidbuser`` account will be
  reset.  (If password authentication was already used, the password
  does not get reset).

- LDAPI (ldappasswd) and need to be root


Demo
----

Here I'll put the full command and command output for an execution
of the ``cert-fix`` tool, and break it up with commentary.  I will
renew the ``subsystem`` certificate, and additionally the
certificate with serial number 29 (which happens to be the LDAP
certificate)::

  [root@f27-1 ~]# pki-server cert-fix \
      --agent-uid admin \
      --ldapi-socket /var/run/slapd-IPA-LOCAL.socket \
      --cert subsystem \
      --extra-cert 29

There is no longer any need to set up an NSSDB with an agent
certificate, a considerable UX improvement!  An further improvement
was to default the log verbosity to ``INFO``, so we can see progress
and observe (at a high level) what the ``cert-fix`` is doing,
without specifying ``-v`` / ``--verbose``.

::

  INFO: Loading password config: /etc/pki/pki-tomcat/password.conf
  INFO: Fixing the following system certs: ['subsystem']
  INFO: Renewing the following additional certs: ['29']
  SASL/EXTERNAL authentication started
  SASL username: gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth
  SASL SSF: 0

Preliminaries.  The tool loads information about the Dogtag
instance, states its intentions and verifies that it can
authenticate to LDAP.

::

  INFO: Stopping the instance to proceed with system cert renewal
  INFO: Configuring LDAP password authentication
  INFO: Setting pkidbuser password via ldappasswd
  SASL/EXTERNAL authentication started
  SASL username: gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth
  SASL SSF: 0
  INFO: Selftests disabled for subsystems: ca
  INFO: Resetting password for uid=admin,ou=people,o=ipaca
  SASL/EXTERNAL authentication started
  SASL username: gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth
  SASL SSF: 0

``cert-fix`` stopped Dogtag, changed the database connection
configuration, reset the agent password and suppressed the Dogtag
self-tests.

::
 
  INFO: Starting the instance
  INFO: Sleeping for 10 seconds to allow server time to start...

``cert-fix`` starts Dogtag then sleeps for a bit.  The sleep was
added to avoid races against Dogtag startup that sometimes caused
the tool to fail.  It's a bit of a hack, but 10 seconds should
*hopefully* be enough.

::

  INFO: Requesting new cert for subsystem
  INFO: Getting subsystem cert info for ca
  INFO: Trying to setup a secure connection to CA subsystem.
  INFO: Secure connection with CA is established.
  INFO: Placing cert creation request for serial: 34
  INFO: Request ID: 38
  INFO: Request Status: complete
  INFO: Serial Number: 0x26
  INFO: Issuer: CN=Certificate Authority,O=IPA.LOCAL 201903151111
  INFO: Subject: CN=CA Subsystem,O=IPA.LOCAL 201903151111
  INFO: New cert is available at: /etc/pki/pki-tomcat/certs/subsystem.crt
  INFO: Requesting new cert for 29; writing to /etc/pki/pki-tomcat/certs/29-renewed.crt
  INFO: Trying to setup a secure connection to CA subsystem.
  INFO: Secure connection with CA is established.
  INFO: Placing cert creation request for serial: 29
  INFO: Request ID: 39
  INFO: Request Status: complete
  INFO: Serial Number: 0x27
  INFO: Issuer: CN=Certificate Authority,O=IPA.LOCAL 201903151111
  INFO: Subject: CN=f27-1.ipa.local,O=IPA.LOCAL 201903151111
  INFO: New cert is available at: /etc/pki/pki-tomcat/certs/29-renewed.crt

Certificate requests were issued and completed successfully.

::

  INFO: Stopping the instance
  INFO: Getting subsystem cert info for ca
  INFO: Getting subsystem cert info for ca
  INFO: Updating CS.cfg with the new certificate
  INFO: Importing new subsystem cert into uid=pkidbuser,ou=people,o=ipaca
  SASL/EXTERNAL authentication started
  SASL username: gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth
  SASL SSF: 0
  modifying entry "uid=pkidbuser,ou=people,o=ipaca"

Dogtag was stopped, and the new subsystem cert was updated in
``CS.cfg``.  It was also imported into the ``pkidbuser`` entry to
ensure LDAP TLS client authentication continues to work.  No further
action is taken in relation to the extra cert(s).

::

  INFO: Selftests enabled for subsystems: ca
  INFO: Restoring previous LDAP configuration
  INFO: Starting the instance with renewed certs

Self-tests are re-enabled and the previous LDAP configuration
restored.  Python *context managers* are used to ensure that these
steps are performed even when a fatal error occurs.

The end.


Conclusion
----------

The problem of an expired CA certificate (issue **#4**) has not yet
been addressed.  It is not the highest priority but it would be nice
to have.  It is still believed to be a low-effort change so it is
likely to be implemented at some stage.

More extensive testing of the tool is needed for renewing system
certificates for other Dogtag subsystems—in particular the KRA
subsystem.

The enhancements discussed in this post make the ``cert-fix`` tool a
viable MVP for expired certificate recovery without time-travel.
The enhancements are still in review, yet to be merged.  That will
hopefully happen soon (within a day or so of this post).  We are
also making a significant effort to backport ``cert-fix`` to some
earlier branches and make it available on older releases.

As mentioned earlier in the post, we intend to implement a
FreeIPA-specific wrapper for ``cert-fix`` that can take care of the
additional steps required to renew and deploy expired certificates
that are part of the FreeIPA system, but are not Dogtag system
certificates handled directly by ``cert-fix``.  These include LDAP
and Apache HTTPD certificates, the IPA RA agent certificate and the
Kerberos PKINIT certificate.
