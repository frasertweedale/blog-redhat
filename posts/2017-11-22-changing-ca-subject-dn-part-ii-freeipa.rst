Changing a CA's Subject DN; Part II: FreeIPA
============================================

In the `previous post`_ I explained how the CA Subject DN is an
integral part of X.509 any why you should not change it.  Doing so
can break path validation, CRLs and OCSP, and many programs will not
copye with the change.  I proposed some alternative approaches that
avoid these problems: re-chaining the CA, and creating subordinate
CAs.

.. _previous post: 2017-11-20-changing-ca-subject-dn-part-i.html

If you were thinking of changing your CA's Subject DN, I hope that I
dissuaded you.  But if I failed, or you absolutely do need to change
the Subject DN of your CA, where there's a will there's way.  The
purpose of this post is to explore how to do this in FreeIPA, and
discuss the implications.

This is a **long post**.  If you are really changing the CA subject
DN, don't skip anything.  Otherwise don't feel bad about skimming
or jumping straight to the `discussion <#discussion>`_.  Even
skimming the article will give you an idea of the steps involved,
and how to repair the ensuing breakage.


Changing the FreeIPA CA's Subject DN
------------------------------------

Before writing this post, I had never even attempted to do this.  I
am unaware of anyone else trying or whether they were successful.
But the question of how to do it has come up several times, so I
decided to investigate.  The format of this post follows my
exploration of the topic as I poked and prodded a FreeIPA
deployment, working towards the goal.

What was the goal?  Let me state the goal, and some assumptions:

- The goal is to give the FreeIPA CA a new Subject DN.  The
  deployment should look and behave as though it were originally
  installed with the new Subject.

- We want to keep the old CA certificate in the relevant certificate
  stores and databases, alongside the new certificate.

- The CA is not being re-keyed (I will deal with re-keying in a
  future article).

- We want to be able to do this with both self-signed and
  externally-signed CAs.  It's okay if the process differs.

- It's okay to have manual steps that the administrator must
  perform.

Let's begin on the deployment's *CA renewal master*.


Certmonger (first attempt)
~~~~~~~~~~~~~~~~~~~~~~~~~~

There is a Certmonger tracking request for the FreeIPA CA, which
uses the ``dogtag-ipa-ca-renew-agent`` CA helper.  The ``getcert
resubmit`` command lets you change the Subject DN when you resubmit
a request, via the ``-N`` option.  I know the internals of the CA
helper and I can see that there will be problems *after* renewing
the certificate this way.  Storing the certificate in the
``ca_renewal`` LDAP container will fail.  But the renewal itself
*might* succeed so I'll try it and see what happens::

  [root@f27-2 ~]# getcert resubmit -i 20171106062742 \
    -N 'CN=IPA.LOCAL CA 2017.11.09'
  Resubmitting "20171106062742" to "dogtag-ipa-ca-renew-agent".

After waiting about 10 seconds for Certmonger to do its thing, I
check the state of the tracking request::

  [root@f27-2 ~]# getcert list -i 20171106062742
  Request ID '20171106062742':
    status: MONITORING
    CA: dogtag-ipa-ca-renew-agent
    issuer: CN=Certificate Authority,O=IPA.LOCAL 201711061603
    subject: CN=Certificate Authority,O=IPA.LOCAL 201711061603
    expires: 2037-11-06 17:26:21 AEDT
    ... (various fields omitted)

The ``status`` and ``expires`` fields show that renewal succeeded,
but the certificate still has the old Subject DN.  This happened
because the ``dogtag-ipa-ca-renew-agent`` helper doesn't think it is
renewing the CA certificate (which is true!)

Modifying the IPA CA entry
~~~~~~~~~~~~~~~~~~~~~~~~~~

So let's trick the Certmonger renewal helper.
``dogtag-ipa-ca-renew-agent`` looks up the CA Subject DN in the
``ipaCaSubjectDn`` attribute of the ``ipa`` CA entry
(``cn=ipa,cn=cas,cn=ca,{basedn}``).  This attribute is not writeable
via the IPA framework but you can change it using regular LDAP tools
(details out of scope).  If the certificate is self-signed you
should also change the ``ipaCaIssuerDn`` attribute.  After modifying
the entry run ``ipa ca-show`` to verify that these attributes have
the desired values::

  [root@f27-2 ~]# ipa ca-show ipa
    Name: ipa
    Description: IPA CA
    Authority ID: cdbfeb5a-64d2-4141-98d2-98c005802fc1
    Subject DN: CN=IPA.LOCAL CA 2017.11.09
    Issuer DN: CN=IPA.LOCAL CA 2017.11.09
    Certificate: MIIDnzCCAoegAwIBAgIBCTANBgkqhkiG9w0...

Certmonger (second attempt)
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Now let's try and renew the CA certificate via Certmonger again::

  [root@f27-2 ~]# getcert resubmit -i 20171106062742 \
    -N 'CN=IPA.LOCAL CA 2017.11.09'
  Resubmitting "20171106062742" to "dogtag-ipa-ca-renew-agent".

Checking the ``getcert list`` output after a short wait::

  [root@f27-2 ~]# getcert list -i 20171106062742
  Request ID '20171106062742':
    status: MONITORING
    CA: dogtag-ipa-ca-renew-agent
    issuer: CN=Certificate Authority,O=IPA.LOCAL 201711061603
    subject: CN=IPA.LOCAL CA 2017.11.09
    expires: 2037-11-09 16:11:12 AEDT
    ... (various fields omitted)

Progress!  We now have a CA certificate with the desired Subject DN.
The new certificate has the old (current) issuer DN.  We'll ignore
that for now.

Checking server health
~~~~~~~~~~~~~~~~~~~~~~

Now I need to check the state of the deployment.  Did anything go
wrong during renewal?  Is everything working?

First, I checked the Certmonger journal output to see if there were
any problems.  The journal contained the following messages (some
fields omitted for brevity)::

  16:11:17 /dogtag-ipa-ca-renew-agent-submit[1662]: Forwarding request to dogtag-ipa-renew-agent
  16:11:17 /dogtag-ipa-ca-renew-agent-submit[1662]: dogtag-ipa-renew-agent returned 0
  16:11:19 /stop_pkicad[1673]: Stopping pki_tomcatd
  16:11:20 /stop_pkicad[1673]: Stopped pki_tomcatd
  16:11:22 /renew_ca_cert[1710]: Updating CS.cfg
  16:11:22 /renew_ca_cert[1710]: Updating CA certificate failed: no matching entry found
  16:11:22 /renew_ca_cert[1710]: Starting pki_tomcatd
  16:11:34 /renew_ca_cert[1710]: Started pki_tomcatd
  16:11:34 certmonger[2013]: Certificate named "caSigningCert cert-pki-ca" in token "NSS Certificate DB" in database "/etc/pki/pki-tomcat/alias" issued by CA and saved.

We can see that the renewal succeeded and Certmonger saved the new
certificate in the NSSDB.  Unfortunately there was an error in the
``renew_ca_cert`` post-save hook: it failed to store the new
certificate in the LDAP certstore.  That should be easy to resolve.
I'll make a note of that and continue checking deployment health.

Next, I checked whether Dogtag was functioning.  ``systemctl status
pki-tomcatd@pki-tomcat`` and the CA debug log
(``/var/log/pki/pki-tomcat/ca/debug``) indicated that Dogtag started
cleanly.  Even better, the Dogtag NSSDB has the new CA certificate
with the correct nickname::

  [root@f27-2 ~]# certutil -d /etc/pki/pki-tomcat/alias \
    -L -n 'caSigningCert cert-pki-ca'
  Certificate:
      Data:
          Version: 3 (0x2)
          Serial Number: 11 (0xb)
          Signature Algorithm: PKCS #1 SHA-256 With RSA Encryption
          Issuer: "CN=Certificate Authority,O=IPA.LOCAL 201711061603"
          Validity:
              Not Before: Thu Nov 09 05:11:12 2017
              Not After : Mon Nov 09 05:11:12 2037
          Subject: "CN=IPA.LOCAL CA 2017.11.09"
    ... (remaining lines omitted)

We have not yet confirmed that the Dogtag uses the new CA Subject DN as the Issuer DN on new certificates (we'll check this later).

Now let's check the state of IPA itself.  There is a problem in
communication between the IPA framework and Dogtag::

  [root@f27-2 ~]# ipa ca-show ipa
  ipa: ERROR: Request failed with status 500: Non-2xx response from CA REST API: 500.

A quick look in ``/var/log/httpd/access_log`` showed that it was not
a general problem but only occurred when accessing a particular
resource::

  [09/Nov/2017:17:15:09 +1100] "GET https://f27-2.ipa.local:443/ca/rest/authorities/cdbfeb5a-64d2-4141-98d2-98c005802fc1/cert HTTP/1.1" 500 6201

That is a Dogtag *lightweight authority* resource for the CA
identified by ``cdbfeb5a-64d2-4141-98d2-98c005802fc1``.  That is the
*CA ID* recorded in the FreeIPA ``ipa`` CA entry.  This gives a hint
about where the problem lies.  An ``ldapsearch`` reveals more::

  [f27-2:~] ftweedal% ldapsearch -LLL \
      -D 'cn=directory manager' -w DM_PASSWORD \
      -b 'ou=authorities,ou=ca,o=ipaca' -s one
  dn: cn=cdbfeb5a-64d2-4141-98d2-98c005802fc1,ou=authorities,ou=ca,o=ipaca
  authoritySerial: 9
  objectClass: authority
  objectClass: top
  cn: cdbfeb5a-64d2-4141-98d2-98c005802fc1
  authorityID: cdbfeb5a-64d2-4141-98d2-98c005802fc1
  authorityKeyNickname: caSigningCert cert-pki-ca
  authorityEnabled: TRUE
  authorityDN: CN=Certificate Authority,O=IPA.LOCAL 201711061603
  description: Host authority

  dn: cn=008a4ded-fd4b-46fe-8614-68518123c95f,ou=authorities,ou=ca,o=ipaca
  objectClass: authority
  objectClass: top
  cn: 008a4ded-fd4b-46fe-8614-68518123c95f
  authorityID: 008a4ded-fd4b-46fe-8614-68518123c95f
  authorityKeyNickname: caSigningCert cert-pki-ca
  authorityEnabled: TRUE
  authorityDN: CN=IPA.LOCAL CA 2017.11.09
  description: Host authority

There are now two authority entries when there should be one.
During startup, Dogtag makes sure it has an authority entry for the
main ("host") CA.  It compares the Subject DN from the signing
certificate in its NSSDB to the authority entries.  If it doesn't
find a match it creates a new entry, and that's what happened here.

The resolution is straightforward:

1. Stop Dogtag
2. Update the ``authorityDN`` and ``authoritySerial`` attributes of
   the *original* host authority entry.
3. Delete the *new* host authority entry.
4. Restart Dogtag.

Now the previous ``ldapsearch`` returns one entry, with the original
authority ID and correct attribute values::

  [f27-2:~] ftweedal% ldapsearch -LLL \
      -D 'cn=directory manager' -w DM_PASSWORD \
      -b 'ou=authorities,ou=ca,o=ipaca' -s one
  dn: cn=cdbfeb5a-64d2-4141-98d2-98c005802fc1,ou=authorities,ou=ca,o=ipaca
  authoritySerial: 11
  authorityDN: CN=IPA.LOCAL CA 2017.11.09
  objectClass: authority
  objectClass: top
  cn: cdbfeb5a-64d2-4141-98d2-98c005802fc1
  authorityID: cdbfeb5a-64d2-4141-98d2-98c005802fc1
  authorityKeyNickname: caSigningCert cert-pki-ca
  authorityEnabled: TRUE
  description: Host authority

And the operations that were failing before (e.g. ``ipa ca-show
ipa``) now succeed.  So we've confirmed, or restored, the basic
functionality on this server.

LDAP certificate stores
~~~~~~~~~~~~~~~~~~~~~~~

There are two LDAP certificate stores in FreeIPA.  The first is
``cn=ca_renewal,cn=ipa,cn=etc,{basedn}``.  It is only used for
replicating Dogtag CA and system certificates from the CA renewal
master to CA replicas.  The ``dogtag-ipa-ca-renew-agent`` Certmonger
helper should update the ``cn=caSigningCert
cert-pki-ca,cn=ca_renewal,cn=ipa,cn=etc,{basedn}`` entry after
renewing the CA certificate.  A quick ``ldapsearch`` shows that this
succeeded, so there is nothing else to do here.

The other certificate store is
``cn=certificates,cn=ipa,cn=etc,{basedn}``.  This store contains
trusted CA certificates.  FreeIPA clients and servers retrieve
certificates from this directory when updating their certificate
trust stores.  Certificates are stored in this container with a
``cn`` based on the Subject DN, except for the IPA CA which is
stored with ``cn={REALM-NAME} IPA CA``.  (In my case, this is
``cn=IPA.LOCAL IPA CA``.)

We discovered the failure to update this certificate store earlier
(in the Certmonger journal).  Now we must fix it up.  We still want
to trust certificates with the old Issuer DN, otherwise we would
have to reissue *all of them*.  So we need to keep the old CA
certificate in the store, alongside the new.

The process to fix up the certificate store is:

1. Export the new CA certificate from the Dogtag NSSDB to a file::

    [root@f27-2 ~]# certutil -d /etc/pki/pki-tomcat/alias \
       -L -a -n 'caSigningCert cert-pki-ca' > new-ca.crt

2. Add the new CA certificate to the certificate store::

    [root@f27-2 ~]# ipa-cacert-manage install new-ca.crt
    Installing CA certificate, please wait
    CA certificate successfully installed
    The ipa-cacert-manage command was successful

3. Rename (``modrdn``) the existing ``cn={REALM-NAME} IPA CA`` entry.
   The new ``cn`` RDN is based on the old CA Subject DN.

4. Rename the new CA certificate entry.  The current ``cn`` is the
   new Subject DN.  Rename it to ``cn={REALM-NAME} IPA CA``.  I
   encountered a 389DS attribute uniqueness error when I attempted
   to do this as a ``modrdn`` operation.  I'm not sure why it
   happened.  To work around the problem I deleted the entry and
   added it back with the new ``cn``.

At the end of this procedure the certificate store is as it should
be.  The CA certificate with new Subject DN is installed as
``{REALM-NAME} IPA CA`` and the old CA certificate has been
preserved under a different RDN.

Updating certificate databases
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The LDAP certificate stores have the new CA certificate.  Now we
need to update the other certificate databases so that the programs
that use them will trust certificates with the new Issuer DN.  These
databases include:

``/etc/ipa/ca.crt``
  CA trust store used by the IPA framework
``/etc/ipa/nssdb``
  An NSSDB used by FreeIPA
``/etc/dirsrv/slapd-{REALM-NAME}``
  NSSDB used by 389DS
``/etc/httpd/alias``
  NSSDB used by Apache HTTPD
``/etc/pki/ca-trust/source/ipa.p11-kit``
  Adds FreeIPA CA certificates to the system-wide trust store

Run ``ipa-certupdate`` to update these databases with the CA
certificates from the LDAP CA certificate store::

  [root@f27-2 ~]# ipa-certupdate
  trying https://f27-2.ipa.local/ipa/json
  [try 1]: Forwarding 'schema' to json server 'https://f27-2.ipa.local/ipa/json'
  trying https://f27-2.ipa.local/ipa/session/json
  [try 1]: Forwarding 'ca_is_enabled/1' to json server 'https://f27-2.ipa.local/ipa/session/json'
  [try 1]: Forwarding 'ca_find/1' to json server 'https://f27-2.ipa.local/ipa/session/json'
  failed to update IPA.LOCAL IPA CA in /etc/dirsrv/slapd-IPA-LOCAL: Command '/usr/bin/certutil -d /etc/dirsrv/slapd-IPA-LOCAL -A -n IPA.LOCAL IPA CA -t C,, -a -f /etc/dirsrv/slapd-IPA-LOCAL/pwdfile.txt' returned non-zero exit status 255.
  failed to update IPA.LOCAL IPA CA in /etc/httpd/alias: Command '/usr/bin/certutil -d /etc/httpd/alias -A -n IPA.LOCAL IPA CA -t C,, -a -f /etc/httpd/alias/pwdfile.txt' returned non-zero exit status 255.
  failed to update IPA.LOCAL IPA CA in /etc/ipa/nssdb: Command '/usr/bin/certutil -d /etc/ipa/nssdb -A -n IPA.LOCAL IPA CA -t C,, -a -f /etc/ipa/nssdb/pwdfile.txt' returned non-zero exit status 255.
  Systemwide CA database updated.
  Systemwide CA database updated.
  The ipa-certupdate command was successful
  [root@f27-2 ~]# echo $?
  0

``ipa-certupdate`` reported that it was successful and it exited
cleanly.  But a glance at the output shows that not all went well.
There were failures added the new CA certificate to several NSSDBs.
Running one of the commands manually to see the command output
doesn't give us much more information::

  [root@f27-2 ~]# certutil -d /etc/ipa/nssdb -f /etc/ipa/nssdb/pwdfile.txt \
      -A -n 'IPA.LOCAL IPA CA' -t C,, -a < ~/new-ca.crt
  certutil: could not add certificate to token or database: SEC_ERROR_ADDING_CERT: Error adding certificate to database.
  [root@f27-2 ~]# echo $?
  255

At this point I guessed that because there is already a certificate
stored with the nickname ``IPA.LOCAL IPA CA``, NSS refuses to add a
certificate with a different Subject DN under the same nickname.  So
I will delete the certificates with this nickname from each of the
NSSDBs, then try again.  For some reason the nickname appeared twice
in each NSSDB::

  [root@f27-2 ~]# certutil -d /etc/dirsrv/slapd-IPA-LOCAL -L

  Certificate Nickname                                         Trust Attributes
                                                               SSL,S/MIME,JAR/XPI

  CN=alt-f27-2.ipa.local,O=Example Organization                u,u,u
  CN=CA,O=Example Organization                                 C,,
  IPA.LOCAL IPA CA                                             CT,C,C
  IPA.LOCAL IPA CA                                             CT,C,C

So for each NSSDB, to delete the certificate I had to execute the
``certutil`` command twice.  For the 389DS NSSDB, the command was::

  [root@f27-2 ~]# certutil -d /etc/httpd/alias -D -n "IPA.LOCAL IPA CA"

The commands for the other NSSDBs were similar.  With the
problematic certificates removed, I tried running ``ipa-certupdate``
again::

  [root@f27-2 ~]# ipa-certupdate
  trying https://f27-2.ipa.local/ipa/session/json
  [try 1]: Forwarding 'ca_is_enabled/1' to json server 'https://f27-2.ipa.local/ipa/session/json'
  [try 1]: Forwarding 'ca_find/1' to json server 'https://f27-2.ipa.local/ipa/session/json'
  Systemwide CA database updated.
  Systemwide CA database updated.
  The ipa-certupdate command was successful
  [root@f27-2 ~]# echo $?
  0

This time there were no errors.  ``certutil`` shows an ``IPA.LOCAL
IPA CA`` certificate in the database, and it's the right
certificate::

  [root@f27-2 ~]# certutil -d /etc/dirsrv/slapd-IPA-LOCAL -L

  Certificate Nickname                                         Trust Attributes
                                                               SSL,S/MIME,JAR/XPI

  CN=alt-f27-2.ipa.local,O=Example Organization                u,u,u
  CN=CA,O=Example Organization                                 C,,
  CN=Certificate Authority,O=IPA.LOCAL 201711061603            CT,C,C
  CN=Certificate Authority,O=IPA.LOCAL 201711061603            CT,C,C
  IPA.LOCAL IPA CA                                             C,,
  [root@f27-2 ~]# certutil -d /etc/dirsrv/slapd-IPA-LOCAL -L -n 'IPA.LOCAL IPA CA'
  Certificate:
      Data:
          Version: 3 (0x2)
          Serial Number: 11 (0xb)
          Signature Algorithm: PKCS #1 SHA-256 With RSA Encryption
          Issuer: "CN=Certificate Authority,O=IPA.LOCAL 201711061603"
          Validity:
              Not Before: Thu Nov 09 05:11:12 2017
              Not After : Mon Nov 09 05:11:12 2037
          Subject: "CN=IPA.LOCAL CA 2017.11.09"
          ...

I also confirmed that the old and new CA certificates are present in
the ``/etc/ipa/ca.crt`` and ``/etc/pki/ca-trust/source/ipa.p11-kit``
files.  So all the certificate databases now include the new CA
certificate.


Renewing the CA certificate (again)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Observe that (in the self-signed FreeIPA CA case) the Issuer DN of
the new CA certificate is the Subject DN of the old CA certificate.
So we have not quite reached out goal.  The original CA certificate
was self-signed, so we want a self-signed certificate with the new
Subject.

Renewing the CA certificate one more time should result in a
self-signed certificate.  The current situation is not likely to
result in operational issues.  So you can consider this an optional
step.  Anyhow, let's give it a go::

  [root@f27-2 ~]# getcert list -i 20171106062742 | egrep 'status|issuer|subject'
          status: MONITORING
          issuer: CN=Certificate Authority,O=IPA.LOCAL 201711061603
          subject: CN=IPA.LOCAL CA 2017.11.09
  [root@f27-2 ~]# getcert resubmit -i 20171106062742
  Resubmitting "20171106062742" to "dogtag-ipa-ca-renew-agent".
  [root@f27-2 ~]# sleep 5
  [root@f27-2 ~]# getcert list -i 20171106062742 | egrep 'status|issuer|subject'
          status: MONITORING
          issuer: CN=IPA.LOCAL CA 2017.11.09
          subject: CN=IPA.LOCAL CA 2017.11.09

Now we have a self-signed CA cert with the new Subject DN.  This
step has also confirmed that that the certificate issuance is
working fine with the new CA subject.


Renewing FreeIPA service certificates
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

This is another optional step, because we have kept the old CA
certificate in the trust store.  I want to check that certificate
renewals via the FreeIPA framework are working, and this is a fine
way to do that.

I'll renew the HTTP service certificate.  This deployment is using
an externally-signed HTTP certificate so first I had to track it::

  [root@f27-2 ~]# getcert start-tracking \
    -d /etc/httpd/alias -p /etc/httpd/alias/pwdfile.txt \
    -n 'CN=alt-f27-2.ipa.local,O=Example Organization' \
    -c IPA -D 'f27-2.ipa.local' -K 'HTTP/f27-2.ipa.local@IPA.LOCAL'
  New tracking request "20171121071700" added.

Then I resubmitted the tracking request.  I had to include the ``-N
<SUBJECT>`` option because the current Subject DN would be rejected
by FreeIPA.  I also had to include the ``-K <PRINC_NAME>`` option
due to `a bug in Certmonger`_.

.. _a bug in Certmonger: https://pagure.io/certmonger/issue/85

::

  [root@f27-2 ~]# getcert resubmit -i 20171121073608 \
    -N 'CN=f27-2.ipa.local' \
    -K 'HTTP/f27-2.ipa.local@IPA.LOCAL'
  Resubmitting "20171121073608" to "IPA".
  [root@f27-2 ~]# sleep 5
  [root@f27-2 ~]# getcert list -i 20171121073608 \
    | egrep 'status|error|issuer|subject'
        status: MONITORING
        issuer: CN=IPA.LOCAL CA 2017.11.09
        subject: CN=f27-2.ipa.local,O=IPA.LOCAL 201711061603

The renewal succeeded, proving that certificate issuance via the
FreeIPA framework is working.


Checking replica health
-----------------------

At this point, I'm happy with the state of the FreeIPA server.  But
so far I have only dealt with one server in the topology (the
renewal master, whose hostname is ``f27-2.ipa.local``).  What about
other CA replicas?

I log onto ``f27-1.ipa.local`` (a CA replica).  As a first step I
execute ``ipa-certupdate``.  This failed in the same was as on the
renewal master, and the steps to resolve were the same.

Next I tell Certmonger to renew the CA certificate.  This should not
renew the CA certificate, only retrieve the certificate from the
LDAP certificate store::

  [root@f27-1 ~]# getcert list -i 20171106064548 \
    | egrep 'status|error|issuer|subject'
          status: MONITORING
          issuer: CN=Certificate Authority,O=IPA.LOCAL 201711061603
          subject: CN=Certificate Authority,O=IPA.LOCAL 201711061603
  [root@f27-1 ~]# getcert resubmit -i 20171106064548
  Resubmitting "20171106064548" to "dogtag-ipa-ca-renew-agent".
  [root@f27-1 ~]# sleep 30
  [root@f27-1 ~]# getcert list -i 20171106064548 | egrep 'status|error|issuer|subject'
          status: MONITORING
          issuer: CN=Certificate Authority,O=IPA.LOCAL 201711061603
          subject: CN=Certificate Authority,O=IPA.LOCAL 201711061603

Well, that did not work.  Instead of retrieving the new CA
certificate from LDAP, the CA replica issued a new certificate::

  [root@f27-1 ~]# certutil -d /etc/pki/pki-tomcat/alias -L \
      -n 'caSigningCert cert-pki-ca'
  Certificate:
      Data:
          Version: 3 (0x2)
          Serial Number: 268369927 (0xfff0007)
          Signature Algorithm: PKCS #1 SHA-256 With RSA Encryption
          Issuer: "CN=Certificate Authority,O=IPA.LOCAL 201711061603"
          Validity:
              Not Before: Tue Nov 21 08:18:09 2017
              Not After : Fri Nov 06 06:26:21 2037
          Subject: "CN=Certificate Authority,O=IPA.LOCAL 201711061603"
          ...

This was caused by the first problem we faced when renewing the CA
certificate with a new Subject DN.  Once again, a mismatch between
the Subject DN in the CSR and the FreeIPA CA's Subject DN has
confused the renewal helper.

The resolution in this case is to delete all the certificates with
nickname ``caSigningCert cert-pki-ca`` or ``IPA.LOCAl IPA CA`` from
Dogtag's NSSDB then add the new CA certificate to the NSSDB.  Then
run ``ipa-certupdate`` again.  Dogtag must not be running during
this process::

  [root@f27-1 ~]# systemctl stop pki-tomcatd@pki-tomcat
  [root@f27-1 ~]# cd /etc/pki/pki-tomcat/alias
  [root@f27-1 ~]# certutil -d . -D -n 'caSigningCert cert-pki-ca'
  [root@f27-1 ~]# certutil -d . -D -n 'caSigningCert cert-pki-ca'
  [root@f27-1 ~]# certutil -d . -D -n 'caSigningCert cert-pki-ca'
  [root@f27-1 ~]# certutil -d . -D -n 'caSigningCert cert-pki-ca'
  certutil: could not find certificate named "caSigningCert cert-pki-ca": SEC_ERROR_BAD_DATABASE: security library: bad database.
  [root@f27-1 ~]# certutil -d . -D -n 'IPA.LOCAL IPA CA'
  [root@f27-1 ~]# certutil -d . -D -n 'IPA.LOCAL IPA CA'
  [root@f27-1 ~]# certutil -d . -D -n 'IPA.LOCAL IPA CA'
  certutil: could not find certificate named "IPA.LOCAL IPA CA": SEC_ERROR_BAD_DATABASE: security library: bad database.
  [root@f27-1 ~]# certutil -d . -A \
      -n 'caSigningCert cert-pki-ca' -t 'CT,C,C' < /root/ipa-ca.pem
  [root@f27-1 ~]# ipa-certupdate
  trying https://f27-1.ipa.local/ipa/json
  [try 1]: Forwarding 'ca_is_enabled' to json server 'https://f27-1.ipa.local/ipa/json'
  [try 1]: Forwarding 'ca_find/1' to json server 'https://f27-1.ipa.local/ipa/json'
  Systemwide CA database updated.
  Systemwide CA database updated.
  The ipa-certupdate command was successful
  [root@f27-1 ~]# systemctl start pki-tomcatd@pki-tomcat

Dogtag started without issue and I was able to issue a certificate
via the ``ipa cert-request`` command on this replica.


Discussion
----------

It took a while and required a lot of manual effort, but I reached
the goal of changing the CA Subject DN.  The deployment seems to be
operational, although my testing was not exhaustive and there may be
breakage that I did not find.

One of the goals was to define the process for both self-signed and
externally-signed CAs.  I did not deal with the externally-signed CA
case.  This article (and the process of writing it) was long enough
without it!  But much of the process, and problems encountered, will
be the same.

There are some important concerns and caveats to be aware of.

First, CRLs generated after the Subject DN change may be bogus.
They will be issued by the new CA but will contain serial numbers of
revoked certificates that were issued by the old CA.  Such
assertions are invalid but not harmful in practice because those
serial numbers will never be reused with the new CA.  This is an
implementation detail of Dogtag and not true in general.

But there is a bigger problem related to CRLs.  After the CA name
change, the old CA will never issue another CRL.  This means that
revoked certificates with the old Issuer DN will never again appear
on a CRL issued by the old CA.  Worse, the Dogtag OCSP responder
errors when you query the status of a certificate with the old
Issuer DN.  In sum, this means that there is no way for Dogtag to
revoke a certificate with the old Issuer DN.  Because many systems
*"fail open"* in the event of missing or invalid CRLs or OCSP
errors, this is a potentially **severe security issue**.

Changing a FreeIPA installation's CA Subject DN, whether by the
procedure outlined in this post or by any other, is **unsupported**.
If you try to do it and break your installation, we (the FreeIPA
team) may try to help you recover, to a point.  But we can't
guarantee anything.  *Here be dragons* and all that.

If you think you need to change your CA Subject DN and have not read
the `previous post`_ on this topic, please go and read it.  It
proposes some alternatives that, if applicable, avoid the messy
process and security issues detailed here.  Despite showing you how
to change a FreeIPA installation's CA Subject DN, my advice remains:
**don't do it**.  I hope you will heed it.
