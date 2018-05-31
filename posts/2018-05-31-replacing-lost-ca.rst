Replacing a lost or broken CA in FreeIPA
========================================

*This is a* ***long post****.  If you just want some steps to follow
feel free to `skip ahead`_.*

.. _skip ahead: #recovery-procedure-summarised

Every now and then we have a customer case or a question on the
``freeipa-users`` mailing list about replacing a lost CA.  Usually
the scenario goes something like this:

- FreeIPA was installed (with a CA)
- Replicas were created, but without the CA role
- The original CA master was decommissioned or failed

A variation on this is the removal of the Dogtag instance on the
only CA master in a deployment.  This is less common, because it's a
deliberate act rather than an oversight.  This action might be
performed to clean up a partially-completed but failed execution of
``ipa-ca-install``, leaving the deployment in an inconsistent state.

In either case, the deployment is left without a CA.  There might be
a backup of the original CA keys can can be used to restore a CA, or
there might not.

In this post I will focus on the total loss of a CA.  What is
required to bring up a new CA in an existing IPA deployment, after
the original CA is destroyed?  I'm going to break a test
installation as described above, then work out how to fix it.  The
goal is to produce a recovery procedure for administrators in this
situation.


Prevention is better than cure
------------------------------

Before I go ahead and delete the CA from a deployment, let's talk
about prevention.  Losing your CA is a Big Deal.  Therefore it's
essential not to leave your deployment with only one CA master.  In
earlier times, FreeIPA did not do anything to detect that there was
only one CA master and make a fuss about it.  This was poor UX that
left many users and customers in a precarious situation, and
ultimately to higher support costs for Red Hat.

Today we have some safeguards in place.  In the topology Web UI we
detect a single-CA topology and warn about it.
``ipa-replica-install`` alerts the administrator if there is only
one CA in the topology and suggests to install the RA role on the
new replica.  ``ipa-server-install --uninstall`` warns when you are
uninstalling the last instance of a some server role; this check
includes the CA role.  Eventually, FreeIPA will have some health
check tools that will check for many kinds of problems, including
this one.


Assumptions and starting environment
------------------------------------

I've made some assumptions that reduce the number of steps or remove
potential pitfalls:

- The Subject DN of the replacement CA will be different from the
  original CA.  The key will be different, so this will avoid
  problems with programs that can't handle a *same subject,
  different key* scenario.  It also avoids the need to force the new
  CA to start issuing certificates from some serial number higher
  than any that were previously issued.

- We'll use self-signed CAs.  I can't think of any problems that
  would arise doing this with an externally-signed CA.  But there
  will be fewer steps and it will keep the post focused.  The
  recovery procedure will not be substantially different for
  externally-signed CAs.

For the environment, I'm using builds of the FreeIPA ``master``
branch, somewhere around the ``v4.7`` pre-release.  Master and
replica machines are both running Fedora 28.

There are two servers in the topology.  ``f28-1.ipa.local`` was the
original server and is the only server with the CA role.  The
replica ``f28-0.ipa.local`` was created from ``f28-1``, without a
CA.  The CA subject DN is ``CN=Certificate Authority,O=IPA.LOCAL
201805171453``.  The Kerberos realm name is ``IPA.LOCAL``.


Success criteria
----------------

How do we know when the deployment is repaired?  I will use the
following success criteria:

#. The CA role is installed on a server (in our case, ``f28-0``).
   That server is configured as the CA renewal master.

#. The new CA certificate is present in the LDAP trust store.

#. The old certificate remains in the LDAP trust store, so that
   certificates issued by the old CA are still trusted.

#. Certificates can be issued via ``ipa cert-request``.

#. Existing HTTP and LDAP certificates, issued by the old CA, can be
   successfully renewed by Certmonger using the new CA.

#. A CA replica can be created.


Deleting the CA
---------------

Now I will remove ``f28-1`` from the topology.  Recent versions of
FreeIPA are aware of which roles (e.g. CA, DNS, etc) are installed
on which servers.  In this case, the program correctly detects that
this server contains the only CA instance, and aborts::

  # ipa-server-install --uninstall

  This is a NON REVERSIBLE operation and will delete all data and configuration!
  It is highly recommended to take a backup of existing data and configuration
    using ipa-backup utility before proceeding.

  Are you sure you want to continue with the uninstall procedure? [no]: y
  ipapython.admintool: ERROR    Server removal aborted:
    Deleting this server is not allowed as it would leave your
    installation without a CA.
  ipapython.admintool: ERROR    The ipa-server-install command failed.
    See /var/log/ipaserver-uninstall.log for more information

The ``--ignore-last-of-role`` option suppresses this check.  When we
add that option, the deletion of the server succeeds::

  # ipa-server-install --uninstall --ignore-last-of-role

  This is a NON REVERSIBLE operation and will delete all data and configuration!
  It is highly recommended to take a backup of existing data and configuration
    using ipa-backup utility before proceeding.

  Are you sure you want to continue with the uninstall procedure? [no]: y
  ------------------------------------
  Deleted IPA server "f28-1.ipa.local"
  ------------------------------------
  Shutting down all IPA services
  Configuring certmonger to stop tracking system certificates for KRA
  Configuring certmonger to stop tracking system certificates for CA
  Unconfiguring CA
  Unconfiguring web server
  Unconfiguring krb5kdc
  Unconfiguring kadmin
  Unconfiguring directory server
  Unconfiguring ipa-custodia
  Unconfiguring ipa-otpd
  Removing IPA client configuration
  Removing Kerberos service principals from /etc/krb5.keytab
  Disabling client Kerberos and LDAP configurations
  Redundant SSSD configuration file /etc/sssd/sssd.conf was moved to /etc/sssd/sssd.conf.deleted
  Restoring client configuration files
  Unconfiguring the NIS domain.
  nscd daemon is not installed, skip configuration
  nslcd daemon is not installed, skip configuration
  Systemwide CA database updated.
  Client uninstall complete.
  The ipa-client-install command was successful

Switching back to ``f28-0`` (the CA-less replica), we can see that
the ``f28-1`` is gone for good, and there is no server with the ``CA
server`` role installed::

  % ipa server-find
  --------------------
  1 IPA server matched
  --------------------
    Server name: f28-0.ipa.local
    Min domain level: 0
    Max domain level: 1
  ----------------------------
  Number of entries returned 1
  ----------------------------

  % ipa server-role-find --role "CA server"
  ---------------------
  1 server role matched
  ---------------------
    Server name: f28-0.ipa.local
    Role name: CA server
    Role status: absent
  ----------------------------
  Number of entries returned 1
  ----------------------------

And because of this, we cannot issue certificates::

  % ipa cert-request --principal alice alice.csr
  ipa: ERROR: CA is not configured

OK, time to fix the deployment!


Fixing the deployment
---------------------

The first thing we'll try is just running ``ipa-ca-install``.  This
command installs the CA role on an existing server.  I expect it to
fail, but it might hint at some of the repairs that need to be
performed.

::

  # ipa-ca-install --subject-base "O=IPA.LOCAL NEW CA"
  Directory Manager (existing master) password: XXXXXXXX

  Your system may be partly configured.
  Run /usr/sbin/ipa-server-install --uninstall to clean up.

  Certificate with nickname IPA.LOCAL IPA CA is present in
  /etc/dirsrv/slapd-IPA-LOCAL/, cannot continue.

We will not follow the advice about uninstalling the server.  But
the second message tell us something useful: we need to rename the
CA certificate in ``/etc/dirsrv/slapd-IPA-LOCAL``.

In fact, there are lots of places we need to rename the old CA
certificate, including the LDAP certificate store.  I'll actually
start there.

LDAP certificate store
^^^^^^^^^^^^^^^^^^^^^^

FreeIPA has an LDAP-based store of trusted CA certificates used by
clients and servers.  The ``ipa-certupdate`` command reads
certificates from this trust store and adds them to system trust
stores and server certificate databases.

CA certificates are stored under
``cn=certificates,cn=ipa,cn=etc,{basedn}``.  The ``cn`` of each
certificate entry is based on the Subject DN.  The FreeIPA CA is the
one exception: its ``cn`` is always ``{REALM} IPA CA``.  What are
the current contents of the LDAP trust store?

::

  % ldapsearch -LLL -D "cn=Directory Manager" -wXXXXXXXX \
      -b "cn=certificates,cn=ipa,cn=etc,dc=ipa,dc=local" \
      -s one ipaCertIssuerSerial cn
  dn: cn=IPA.LOCAL IPA CA,cn=certificates,cn=ipa,cn=etc,dc=ipa,dc=local
  ipaCertIssuerSerial: CN=Certificate Authority,O=IPA.LOCAL 201805171453;1
  cn: IPA.LOCAL IPA CA

We see only the FreeIPA CA certificate, as expected.  We must move
this entry aside.  We do still want to keep it in the trust stores
so certificates that were issued by this CA will still be trusted.
I used the ``ldapmodrdn`` command to rename this entry, with the new
``cn`` based on the Subject DN of the old CA.

::

  % ldapmodrdn -D "cn=Directory Manager" -wXXXXXXXX -r \
      "cn=IPA.LOCAL IPA CA,cn=certificates,cn=ipa,cn=etc,dc=ipa,dc=local" \
      "cn=CN\=Certificate Authority\,O\=IPA.LOCAL 201805171453"

  % ldapsearch -LLL -D "cn=Directory Manager" -wXXXXXXXX \
      -b "cn=certificates,cn=ipa,cn=etc,dc=ipa,dc=local" \
      -s one ipaCertIssuerSerial cn
  dn: cn=CN\3DCertificate Authority\2CO\3DIPA.LOCAL 201805171453,cn=certificates,cn=
   ipa,cn=etc,dc=ipa,dc=local
  ipaCertIssuerSerial: CN=Certificate Authority,O=IPA.LOCAL 201805171453;1
  cn: CN=Certificate Authority,O=IPA.LOCAL 201805171453

For the ``ldapmodrdn`` command, note the escaping of the ``=`` and ``,``
characters in the DN.  This is important.


Removing CA entries
^^^^^^^^^^^^^^^^^^^

There are a bunch of CA entries in the FreeIPA directory.  The ``cn=ipa`` is the
main IPA CA.  In additional, there can be zero or more *lightweight
sub-CAs* in a FreeIPA deployment.

::

  # ipa ca-find
  -------------
  2 CAs matched
  -------------
    Name: ipa
    Description: IPA CA
    Authority ID: a0e7a855-aac2-40fc-8e86-cf1a7429f28c
    Subject DN: CN=Certificate Authority,O=IPA.LOCAL 201805171453
    Issuer DN: CN=Certificate Authority,O=IPA.LOCAL 201805171453

    Name: test1
    Authority ID: ac7e6def-acd8-4d19-ab3e-60067c17ba81
    Subject DN: CN=test1
    Issuer DN: CN=Certificate Authority,O=IPA.LOCAL 201805171453
  ----------------------------
  Number of entries returned 2
  ----------------------------

These entries will all need to be removed::

  # ipa ca-find --pkey-only --all \
      | grep dn: \
      | awk '{print $2}' \
      | xargs ldapdelete -D "cn=Directory Manager" -wXXXXXXXX

  # ipa ca-find
  -------------
  0 CAs matched
  -------------
  ----------------------------
  Number of entries returned 0
  ----------------------------


DS NSSDB
^^^^^^^^

``ipa-ca-install`` complained about the presense of a certificate
with nickname ``IPA.LOCAL IPA CA`` in the
``/etc/dirsrv/slapd-IPA-LOCAL`` NSS certificate database (NSSDB).
What are the current contents of this NSSDB?

::

  # certutil -d /etc/dirsrv/slapd-IPA-LOCAL -L

  Certificate Nickname                 Trust Attributes
                                       SSL,S/MIME,JAR/XPI

  IPA.LOCAL IPA CA                     CT,C,C
  Server-Cert                          u,u,u

There are two certificates: the old CA certificate and the server
certificate.

With the CA certificate having been renamed in the LDAP trust store,
I'll now run ``ipa-certupdate`` and see what happens in the NSSDB.

::

  # ipa-certupdate
  trying https://f28-0.ipa.local/ipa/session/json
  [try 1]: Forwarding 'ca_is_enabled/1' to json server
  'https://f28-0.ipa.local/ipa/session/json'
  Systemwide CA database updated.
  Systemwide CA database updated.
  The ipa-certupdate command was successful

Nothing failed!  That is encouraging.  But ``certutil`` still shows
the same output as above.  So we must find another way to change the
nickname in the NSSDB.  Lucky for us, ``certutil`` has a ``rename``
option::

  # certutil --rename --help
  --rename        Change the database nickname of a certificate
     -n cert-name      The old nickname of the cert to rename
     --new-n new-name  The new nickname of the cert to rename
     -d certdir        Cert database directory (default is ~/.netscape)
     -P dbprefix       Cert & Key database prefix

  # certutil -d /etc/dirsrv/slapd-IPA-LOCAL --rename \
      -n 'IPA.LOCAL IPA CA' --new-n 'OLD IPA CA'

  # certutil -d /etc/dirsrv/slapd-IPA-LOCAL -L

  Certificate Nickname                 Trust Attributes
                                       SSL,S/MIME,JAR/XPI

  OLD IPA CA                           CT,C,C
  Server-Cert                          u,u,u

I also performed this rename in ``/etc/ipa/nssdb``.  On Fedora 28,
Apache uses OpenSSL instead of NSS.  But on older versions there is
also an Apache NSSDB at ``/etc/httpd/alias``; the rename will need
to be performed there, too.

``ipa-ca-install``, attempt 2
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Now that the certificates have been renamed in the LDAP trust store
and NSSDBs, let's try ``ipa-ca-install`` again::

  # ipa-ca-install --ca-subject 'CN=IPA.LOCAL NEW CA'
  Directory Manager (existing master) password: XXXXXXXX

  The CA will be configured with:
  Subject DN:   CN=IPA.LOCAL NEW CA
  Subject base: O=IPA.LOCAL
  Chaining:     self-signed

  Continue to configure the CA with these values? [no]: y
  Configuring certificate server (pki-tomcatd). Estimated time: 3 minutes
    [1/28]: configuring certificate server instance
    [2/28]: exporting Dogtag certificate store pin
    [3/28]: stopping certificate server instance to update CS.cfg
    [4/28]: backing up CS.cfg
    [5/28]: disabling nonces
    [6/28]: set up CRL publishing
    [7/28]: enable PKIX certificate path discovery and validation
    [8/28]: starting certificate server instance
    [9/28]: configure certmonger for renewals
    [10/28]: requesting RA certificate from CA
    [error] DBusException: org.fedorahosted.certmonger.duplicate:
            Certificate at same location is already used by request
            with nickname "20180530050017".

Well, we have made progress.  Installation got a fair way along, but
failed because there was already a Certmonger tracking request for
the IPA RA certificate.

Certmonger tracking requests
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

We have to clean up the Certmonger tracking request for the ``IPA
RA`` certificate.  The ``ipa-ca-install`` failure helpfully told us
the ID of the problematic request.  But if we wanted to nail it on
the first try we'd have to look it up.  We can ask Certmonger to
show the tracking request for the certificate file at
``/var/lib/ipa/ra-agent.pem``, where the ``IPA RA`` certificate is
stored::

  # getcert list -f /var/lib/ipa/ra-agent.pem
  Number of certificates and requests being tracked: 4.
  Request ID '20180530050017':
          status: MONITORING
          stuck: no
          key pair storage: type=FILE,location='/var/lib/ipa/ra-agent.key'
          certificate: type=FILE,location='/var/lib/ipa/ra-agent.pem'
          CA: dogtag-ipa-ca-renew-agent
          issuer: CN=Certificate Authority,O=IPA.LOCAL 201805171453
          subject: CN=IPA RA,O=IPA.LOCAL 201805171453
          expires: 2020-05-06 14:55:30 AEST
          key usage: digitalSignature,keyEncipherment,dataEncipherment
          eku: id-kp-serverAuth,id-kp-clientAuth
          pre-save command: /usr/libexec/ipa/certmonger/renew_ra_cert_pre
          post-save command: /usr/libexec/ipa/certmonger/renew_ra_cert
          track: yes
          auto-renew: yes

Then we can stop tracking it::

  # getcert stop-tracking -i 20180530050017
  Request "20180530050017" removed.

Now, before we can run ``ipa-ca-install`` again, we have an unwanted
``pki-tomcat`` instance sitting around.  We need to explicitly
remove it using ``pkidestroy``::

  # pkidestroy -s CA -i pki-tomcat
  Log file: /var/log/pki/pki-ca-destroy.20180530165156.log
  Loading deployment configuration from /var/lib/pki/pki-tomcat/ca/registry/ca/deployment.cfg.
  Uninstalling CA from /var/lib/pki/pki-tomcat.
  pkidestroy  : WARNING  ....... this 'CA' entry will NOT be deleted from security domain 'IPA'!
  pkidestroy  : WARNING  ....... security domain 'IPA' may be offline or unreachable!
  pkidestroy  : ERROR    ....... subprocess.CalledProcessError:  Command '['/usr/bin/sslget', '-n', 'subsystemCert cert-pki-ca', '-p', '7Zc^NEd1%~@rGO%d{)%K:$S5L[^1F1K.!@5oWgZ]e', '-d', '/etc/pki/pki-tomcat/alias', '-e', 'name="/var/lib/pki/pki-tomcat"&type=CA&list=caList&host=f28-0.ipa.local&sport=443&ncsport=443&adminsport=443&agentsport=443&operation=remove', '-v', '-r', '/ca/agent/ca/updateDomainXML', 'f28-0.ipa.local:443']' returned non-zero exit status 3.!
  pkidestroy  : WARNING  ....... Directory '/etc/pki/pki-tomcat/alias' is either missing or is NOT a directory!

  Uninstallation complete.


``ipa-ca-install``, attempt 3
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Here we go again!

::

  # ipa-ca-install --ca-subject 'CN=IPA.LOCAL NEW CA'
  ...
    [10/28]: requesting RA certificate from CA
    [11/28]: setting audit signing renewal to 2 years
    [12/28]: restarting certificate server
    [13/28]: publishing the CA certificate
    [14/28]: adding RA agent as a trusted user
    [15/28]: authorizing RA to modify profiles
    [16/28]: authorizing RA to manage lightweight CAs
    [17/28]: Ensure lightweight CAs container exists
    [18/28]: configure certificate renewals
    [19/28]: configure Server-Cert certificate renewal
    [20/28]: Configure HTTP to proxy connections
    [21/28]: restarting certificate server
    [22/28]: updating IPA configuration
    [23/28]: enabling CA instance
    [24/28]: migrating certificate profiles to LDAP
    [error] RemoteRetrieveError: Failed to authenticate to CA REST API

  Your system may be partly configured.
  Run /usr/sbin/ipa-server-install --uninstall to clean up.

  Unexpected error - see /var/log/ipareplica-ca-install.log for details:
  RemoteRetrieveError: Failed to authenticate to CA REST API

Dang!  This time the installation failed due to an authentication
failure between the IPA framework and Dogtag.  This authentication
uses the IPA RA certificate.  It turns out that Certmonger did not
request a new RA certificate.  Instead, it tracked the preexisting
RA certificate issued by the old CA::

  # openssl x509 -text < /var/lib/ipa/ra-agent.pem |grep Issuer
        Issuer: O = IPA.LOCAL 201805171453, CN = Certificate Authority

The IPA framework presents the old RA certificate when
authenticating to the new CA.  The new CA does not recognise it, so
authentication fails.  Therefore we need to remove the IPA RA
certificate and key before installing a new CA::

  # rm -fv /var/lib/ipa/ra-agent.*
  removed '/var/lib/ipa/ra-agent.key'
  removed '/var/lib/ipa/ra-agent.pem'

Because installation got a fair way along before failing, we also
need to:

- ``pkidestroy`` the Dogtag instance (as before)
- remove Certmonger tracking requests for the RA certificate (as before)
- remove Certmonger tracking requests for Dogtag system certificates
- run ``ipa-certupdate`` to remove the new CA certificate from trust stores

Also, the deployment now believes that the CA role has been
installed on ``f28-0``::

  # ipa server-role-find --role 'CA server'
  ---------------------
  1 server role matched
  ---------------------
    Server name: f28-0.ipa.local
    Role name: CA server
    Role status: enabled
  ----------------------------
  Number of entries returned 1
  ----------------------------

Note ``Role status: enabled`` above.  We need to remove this record
that the CA role is installed on ``f28-0``.  Like so::

  # ldapdelete -D "cn=Directory Manager" -wXXXXXXXX \
      cn=CA,cn=f28-0.ipa.local,cn=masters,cn=ipa,cn=etc,dc=ipa,dc=local

  # ipa server-role-find --role 'CA server'
  ---------------------
  1 server role matched
  ---------------------
    Server name: f28-0.ipa.local
    Role name: CA server
    Role status: absent
  ----------------------------
  Number of entries returned 1
  ----------------------------

Having performed these cleanup tasks, we will try again to install
the CA.


``ipa-ca-install``, attempt 4
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

::

  # ipa-ca-install --ca-subject 'CN=IPA.LOCAL NEW CA'
  ...
    [24/28]: migrating certificate profiles to LDAP
    [25/28]: importing IPA certificate profiles
    [26/28]: adding default CA ACL
    [27/28]: adding 'ipa' CA entry
    [28/28]: configuring certmonger renewal for lightweight CAs
  Done configuring certificate server (pki-tomcatd).

Hooray!  We made it.


Results
-------

Let's revisit each of the success criteria and see whether the goal
has been achieved.

1. CA role installed and configured as renewal master
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

::

  # ipa server-role-find --role 'CA server'
  ---------------------
  1 server role matched
  ---------------------
    Server name: f28-0.ipa.local
    Role name: CA server
    Role status: enabled
  ----------------------------
  Number of entries returned 1
  ----------------------------

  # ipa config-show |grep CA
    Certificate Subject base: O=IPA.LOCAL
    IPA CA servers: f28-0.ipa.local
    IPA CA renewal master: f28-0.ipa.local

Looks like this criterion has been met.

2 & 3. LDAP trust store
^^^^^^^^^^^^^^^^^^^^^^^

::

  # ldapsearch -LLL -D cn="Directory manager" -wXXXXXXXX \
      -b "cn=certificates,cn=ipa,cn=etc,dc=ipa,dc=local" \
      -s one ipaCertIssuerSerial cn
  dn: cn=CN\3DCertificate Authority\2CO\3DIPA.LOCAL 201805171453,cn=certificates
   ,cn=ipa,cn=etc,dc=ipa,dc=local
  ipaCertIssuerSerial: CN=Certificate Authority,O=IPA.LOCAL 201805171453;1
  cn: CN=Certificate Authority,O=IPA.LOCAL 201805171453

  dn: cn=IPA.LOCAL IPA CA,cn=certificates,cn=ipa,cn=etc,dc=ipa,dc=local
  ipaCertIssuerSerial: CN=IPA.LOCAL NEW CA;1
  cn: IPA.LOCAL IPA CA

The old and new CA certificates are present in the LDAP trust store.
The new CA certificate has the appropriate ``cn`` value.  These
criteria have been met.

4. CA can issue certificates
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

::

  # ipa cert-request --principal alice alice.csr
    Issuing CA: ipa
    Certificate: MIIC0zCCAbugAwIBAgIBCDAN...
    Subject: CN=alice,OU=pki-ipa,O=IPA
    Issuer: CN=IPA.LOCAL NEW CA
    Not Before: Thu May 31 05:14:42 2018 UTC
    Not After: Sun May 31 05:14:42 2020 UTC
    Serial number: 8
    Serial number (hex): 0x8

The certificate was issued by the new CA.  Success.

5. Can renew HTTP and LDAP certificates
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Because we are still trusting the old CA, there is no immediate need
to renew the HTTP and LDAP certificate.  But they will eventually
expire, so we need to ensure that renewal works.  ``getcert
resubmit`` is used to initiate a renewal::

  # getcert resubmit -i 20180530045952
  Resubmitting "20180530045952" to "IPA".

  # sleep 10

  # getcert list -i 20180530045952
  Number of certificates and requests being tracked: 9.
  Request ID '20180530045952':
          status: MONITORING
          stuck: no
          key pair storage: type=FILE,location='/var/lib/ipa/private/httpd.key',pinfile='/var/lib/ipa/passwds/f28-0.ipa.local-443-RSA'
          certificate: type=FILE,location='/var/lib/ipa/certs/httpd.crt'
          CA: IPA
          issuer: CN=IPA.LOCAL NEW CA
          subject: CN=f28-0.ipa.local,OU=pki-ipa,O=IPA
          expires: 2020-05-31 15:24:05 AEST
          key usage: digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
          eku: id-kp-serverAuth,id-kp-clientAuth
          pre-save command: 
          post-save command: /usr/libexec/ipa/certmonger/restart_httpd
          track: yes
          auto-renew: yes

The renewal succeeded.  Using ``openssl s_client`` we can see that
the HTTP server is now presenting a certificate chain ending with
the new CA certificate::

  # echo | openssl s_client -showcerts \
      -connect f28-0.ipa.local:443 -servername f28-0.ipa.local \
      | grep s:
  depth=1 CN = IPA.LOCAL NEW CA
  verify return:1
  depth=0 O = IPA, OU = pki-ipa, CN = f28-0.ipa.local
  verify return:1
   0 s:/O=IPA/OU=pki-ipa/CN=f28-0.ipa.local
   1 s:/CN=IPA.LOCAL NEW CA

So we are looking good against this criterion too.

6. A CA replica can be created
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

``f28-1`` was removed from the deployment at the beginning.  To test
CA replica installation, I enrolled it again using
``ipa-client-install``, then executed ``ipa-replica-install
--setup-ca``.  Installation completed successfully::

  # ipa-replica-install --setup-ca
  Password for admin@IPA.LOCAL:
  Run connection check to master
  Connection check OK
  Configuring directory server (dirsrv). Estimated time: 30 seconds
    [1/41]: creating directory server instance
    ...
    [26/26]: configuring certmonger renewal for lightweight CAs
  Done configuring certificate server (pki-tomcatd).
  Configuring Kerberos KDC (krb5kdc)
    [1/1]: installing X509 Certificate for PKINIT
  Full PKINIT configuration did not succeed
  The setup will only install bits essential to the server functionality
  You can enable PKINIT after the setup completed using 'ipa-pkinit-manage'
  Done configuring Kerberos KDC (krb5kdc).
  Applying LDAP updates
  Upgrading IPA:. Estimated time: 1 minute 30 seconds
    [1/9]: stopping directory server
    [2/9]: saving configuration
    [3/9]: disabling listeners
    [4/9]: enabling DS global lock
    [5/9]: starting directory server
    [6/9]: upgrading server
    [7/9]: stopping directory server
    [8/9]: restoring configuration
    [9/9]: starting directory server
  Done.
  Restarting the KDC

We have a clean sweep of the success criteria.  **Mission
accomplished.**


Recovery procedure, summarised
------------------------------

Distilling the trial-and-error exploration above down to the
essential steps, we end up with the following procedure.  Not every
step is necessary in every case, and most steps do not necessarily
have to be performed in the order shown here.

#. Delete CA entries::

    # ipa ca-find --pkey-only --all \
        | grep dn: \
        | awk '{print $2}' \
        | xargs ldapdelete -D "cn=Directory Manager" -wXXXXXXXX

#. Destroy the existing Dogtag instance, if present::

    # pkidestroy -s CA -i pki-tomcat

#. Delete the CA server role entry for the current host, if present.
   For example::

    # ldapdelete -D "cn=Directory Manager" -wXXXXXXXX
        cn=CA,cn=f28-0.ipa.local,cn=masters,cn=ipa,cn=etc,dc=ipa,dc=local

#. Move aside the old IPA CA certificate in the LDAP certificate
   store.  By convention, the new RDN should be based on the subject
   DN.  For example::

    % ldapmodrdn -D "cn=Directory Manager" -wXXXXXXXX -r \
        "cn=IPA.LOCAL IPA CA,cn=certificates,cn=ipa,cn=etc,dc=ipa,dc=local" \
        "cn=CN\=Certificate Authority\,O\=IPA.LOCAL 201805171453"

#. Rename the IPA CA certificate nickname in the NSSDBs at
   ``/etc/dirsrv/slapd-{REALM]``, ``/etc/ipa/nssdb`` and, if
   relevant, ``/etc/httpd/alias``.  Example command::

    # certutil -d /etc/dirsrv/slapd-IPA-LOCAL --rename \
        -n 'IPA.LOCAL IPA CA' --new-n 'OLD IPA CA'

#. Remove Certmonger tracking requests for all Dogtag system
   certificates, and remove the tracking request for the IPA RA
   certificate::

    # for ID in ... ; \
        do certmonger stop-tracking -i $ID ; \
        done

#. Delete the IPA RA certificate and key::

    # rm -fv /var/lib/ipa/ra-agent.*
    removed '/var/lib/ipa/ra-agent.key'
    removed '/var/lib/ipa/ra-agent.pem'

#. Run ``ipa-certupdate``.

#. Run ``ipa-ca-install``.


Conclusion
----------

The procedure developed in this post should cover most cases of CA
installation failure or loss of the only CA master in a deployment.
Inevitably the differences between versions of FreeIPA mean that the
procedure may vary, depending on which version(s) you are using.

In this procedure, the new CA is installed with a different Subject
DN.  Conceptually, this is not essential.  But reusing the same
subject DN could cause problems for some programs.  I `wrote about
this in an earlier post`_.  Furthermore, to keep the CA subject DN
the same would involve extra steps to ensure that serial numbers
were not re-used.  I am not interested in investigating how to pull
this off.  Just choose a new DN!

One feature request we sometimes receive is a CA uninstaller.  The
steps outlined in this post would suffice to uninstall a CA and
erase knowledge of it from a deployment (apart from the CA
certificate itself, which you would probably want to keep).

Looking ahead, I (or maybe someone else) could gather the cleanup
steps into an easy to use script.  Administrators or support
personnel who have run into problems can execute the script to
quickly restore their server to a state where the CA can (hopefully)
successfully be installed.

.. _wrote about this in an earlier post: 2017-11-20-changing-ca-subject-dn-part-i.html
