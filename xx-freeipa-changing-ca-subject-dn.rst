Changning a CA's Subject Distinguished Name
===========================================

When you deploy FreeIPA, you choose a *Subject Distinguished Name*
for the CA (often abbreviated as *Subject DN*, *Subject Name* or
just *Subject*).  If you don't explicitly choose the Subject DN, the
default name looks like ``CN=Certificate Authority, O=YOUR.DOMAIN``.

The Subject DN cannot be changed; it is "for life".  But sometimes
someone wants to change it anyway.  In this article we'll look at
why changing the Subject DN is a challenge, the reasons why someone
would want to change it, and how you can do that in FreeIPA along
with a discussion of the implications.

What is the Subject DN?
-----------------------

A distinguished name (DN) is a sequence of sets of name attribute
types and values.  Common attribute types include *Common Name
(CN)*, *Organisation (O)*, *Organisational Unit (OU)*, *Country (C)*
and so on.

All X.509 certificates contain an *Issuer DN* field and a *Subject
DN* field.  If the same value is used for both issuer and subject,
it is a *self-signed certificate*.  When a CA issues a certificate,
the *Issuer DN* of the issued certificate shall be the *Subject DN*
of the CA certificate.

The Subject DN uniquely identifies a CA.  **It is the CA**.  A CA
can have multiple concurrent certificates, possibly with different
public keys and key types.  But if the Subject DN is the same, they
are merely different certificates for a single CA.  Corollary: if
the Subject DN differs, it is a different CA *even if the key is the
same*.


Changing the CA Subject DN; general considerations
--------------------------------------------------

Changing the CA Subject DN is challenging because all software will
(or should) regard it as a different CA.  If you want to do it,
general considerations include:

- Most CA software does not provide a facility for "renewing" a CA
  to have a different Subject DN.  Some amount of manual work may be
  involved.

- Unlike a regular renewal, when updating trust stores you must keep
  the old certificate as well as adding the new certificate.  (This
  consideration also arises when re-keying a CA.)

- If using the same key, some programs and/or certificate databases
  may have trouble reconciling the use of the new Subject DN with
  the use of the existing key.  That is, they may not cope with the
  concept of *different CAs using the same key*.


Why change the CA Subject DN?
-----------------------------

Why do people want to change the CA Subject DN?  Every explanation I
have heard amounts to *"we don't like the one we have"*, or
occasionally *"it doesn't meet out organisation's guidelines"*.  For
FreeIPA this usually means that the default CA Subject DN was used
during installation, and now they wish for something different.

To be fair, the FreeIPA installer does not prompt for a CA Subject
DN but rather uses the default form unless explicitly told otherwise
via options.  Furthermore, prior to FreeIPA version 4.5, the CA
Subject DN was only partially customisable (specifically, the DN
always started with ``CN=Certificate Authority``).  So in most cases
where an administrator wants to change the CA Subject DN, it is not
because they chose the wrong one, but rather they were *not given
the opportunity to choose the right one*.


Changing the CA Subject DN; FreeIPA
-----------------------------------

So you have a FreeIPA installation and you want to change the CA
Subject DN.  How do you do it, and what are the implications?

Prior to this post, I had never even attempted this.  I don't know
if anyone has, or how successful they were.  But it has come up
enough times to warrant a proper investigation.  This section
recounts the various challenges encountered and outcomes achieved as
I attempt to work this out.

First let's lay down the goals and assumptions:

- The end goal is that the FreeIPA CA has a new Subject DN.  The
  deployment must look and behave as though it had originally been
  installed with this CA, except that the old CA certificate should
  be present in relevant certificate stores alongside the new
  certificate.

- The CA is not being re-keyed (I will deal with re-keying in a
  future article).

- We want to be able to do this with both self-signed and
  externally-signed CAs.  It's okay if the process differs.

- It's okay to have manual steps that the administrator must
  perform.

Let's begin.  We start on the server that is configured as the *CA
renewal master*, and remain there until I mention otherwise.


Certmonger (first attempt)
~~~~~~~~~~~~~~~~~~~~~~~~~~

There is a Certmonger tracking request for the FreeIPA CA, which
uses the ``dogtag-ipa-ca-renew-agent`` CA helper.  The ``getcert
resubmit`` command lets you change the Subject DN when you resubmit
a request, via the ``-N`` option.  I know the internals of the CA
helper and I can see that there will be problems *after* renewing
the certificate this way (specifically, storing the certificate in
the ``ca_renewal`` LDAP container will fail).  But the renewal
itself *might* succeed so I'll just try it and see what happens::

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

We can see that the certificate was renewed, but it kept the old
Subject DN.  Without getting bogged down in details, this happened
because the ``dogtag-ipa-ca-renew-agent`` helper doesn't think it is
renewing the CA certificate (which is true!)

Modifying the IPA CA entry
~~~~~~~~~~~~~~~~~~~~~~~~~~

So let's trick the Certmonger renewal helper.
``dogtag-ipa-ca-renew-agent`` looks up the CA Subject DN in the
``ipaCaSubjectDn`` attribute of the ``ipa`` CA entry
(``cn=ipa,cn=cas,cn=ca,{basedn}``).  This attribute is not
writeable via the IPA framework but you can modify it using
``ldapmodify`` or ``ldapvi`` (details are out of scope).  If the
certificate is self-signed you should also change the
``ipaCaIssuerDn`` attribute.  After modifying the entry run ``ipa
ca-show`` to verify that these attributes have the desired values::

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

Checking deployment health
~~~~~~~~~~~~~~~~~~~~~~~~~~

Now I need to check the state of the deployment.  Did anything go
wrong during renewal?  Is everything working?

First, I check the Certmonger journal output to see if there were
any problems (some date and hostname fields omitted for brevity)::

  16:11:17 /dogtag-ipa-ca-renew-agent-submit[1662]: Forwarding request to dogtag-ipa-renew-agent
  16:11:17 /dogtag-ipa-ca-renew-agent-submit[1662]: dogtag-ipa-renew-agent returned 0
  16:11:19 /stop_pkicad[1673]: Stopping pki_tomcatd
  16:11:20 /stop_pkicad[1673]: Stopped pki_tomcatd
  16:11:22 /renew_ca_cert[1710]: Updating CS.cfg
  16:11:22 /renew_ca_cert[1710]: Updating CA certificate failed: no matching entry found
  16:11:22 /renew_ca_cert[1710]: Starting pki_tomcatd
  16:11:34 /renew_ca_cert[1710]: Started pki_tomcatd
  16:11:34 certmonger[2013]: Certificate named "caSigningCert cert-pki-ca" in token "NSS Certificate DB" in database "/etc/pki/pki-tomcat/alias" issued by CA and saved.

We can see that the renewal helper succeeded and the new certificate
was saved in the NSSDB.  Unfortunately, there was an error in the
``renew_ca_cert`` post-save hook: it failed to store the new
certificate in the LDAP certstore.  That should be easy to resolve.
I'll make a note of that and continue checking deployment health.

Next, I checked whether Dogtag was up and running properly.  A quick
check of ``systemctl status pki-tomcatd@pki-tomcat`` and the CA
debug log ``/var/log/pki/pki-tomcat/ca/debug`` shows that everything
*seems* to be working properly.  Even better, the new certificate
has been installed in the Dogtag NSSDB with the correct nickname::

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

We have not yet confirmed that the new CA Subject DN will be used as
the Issuer DN on subsequent certificates (we'll check this later).

Now let's check the state of IPA itself.  ``ipa cert-show 1`` shows
that there is a problem in communication between the IPA framework
and Dogtag::

  [root@f27-2 ~]# ipa ca-show ipa
  ipa: ERROR: Request failed with status 500: Non-2xx response from CA REST API: 500.

A quick look in ``/var/log/httpd/access_log`` showed that it was not
a general problem but only occurred when accessing a particular
resource::

  [09/Nov/2017:17:15:09 +1100] "GET https://f27-2.ipa.local:443/ca/rest/authorities/cdbfeb5a-64d2-4141-98d2-98c005802fc1/cert HTTP/1.1" 500 6201

That is the Dogtag *lightweight authority* cert resource for the CA
identified by ``cdbfeb5a-64d2-4141-98d2-98c005802fc1``, which was
the "top-level" CA.  This ID is recorded in the FreeIPA ``ipa`` CA
entry.  This gives a hint about where the problem lies.  An
``ldapsearch`` reveals more::

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

Now the previous ``ldapsearch`` returns just the one entry, with the
original authority ID and correct attribute values::

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
``cn=ca_renewal,cn=ipa,cn=etc,{basedn}``, and it is only used for
replicating Dogtag CA and system certificates from the CA renewal
master to CA replicas.  The entry ``cn=caSigningCert
cert-pki-ca,cn=ca_renewal,cn=ipa,cn=etc,{basedn}`` should be updated
by the ``dogtag-ipa-ca-renew-agent`` Certmonger helper during
renewal.  A quick ``ldapsearch`` shows that this process happened
correctly, so there is nothing else to do for this certificate
store.

The other certificate store is
``cn=certificates,cn=ipa,cn=etc,{basedn}``.  This store contains CA
certificates that should be trusted by FreeIPA servers and clients.
Certificates are stored in this container with a ``cn`` based on the
Subject DN, except for the IPA CA which is stored with
``cn={REALM-NAME} IPA CA``.  (In my case, this is ``cn=IPA.LOCAL IPA
CA``.)

The failure to update this certificate store was discovered earlier
in the Certmonger journal.  Now we must fix it up.  Importantly, we
want existing certificates that were issued by the old CA DN to
continue to be trusted (otherwise we would have to re-issue *all*
certificates issued using the old CA Subject DN).

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
   The new ``cn`` RDN should be based on the old CA Subject DN.

4. Rename the new CA certificate entry.  The current ``cn`` is based
   on the new Subject DN.  Rename it to ``cn={REALM-NAME} IPA CA``.
   I encountered a 389DS attribute uniqueness error when I attempted
   to do this as a ``modrdn`` operation.  I'm not sure why it
   happened.  To work around the problem I deleted the entry and
   added it back with the new ``cn``.

At the end of this procedure the certificate store is as it should
be.  The CA certificate with new Subject DN is installed as
``{REALM-NAME} IPA CA`` and the old CA certificate has been
preserved under a different RDN.

Updating certificate databases
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The LDAP certificate stores have the new CA certificate, but other
certificate stores also need to receive the new certificate, so that
certificates issued using the new CA Subject DN will be trusted by
programs.  These databases include:

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
cleanly, but a glance at the output shows that not all went well.
The new CA certificate could not be added to several NSSDBs.

Running one of the commands manually to see the command output
doesn't give us much more information::

  [root@f27-2 ~]# certutil -d /etc/ipa/nssdb -f /etc/ipa/nssdb/pwdfile.txt \
      -A -n 'IPA.LOCAL IPA CA' -t C,, -a < ~/new-ca.crt
  certutil: could not add certificate to token or database: SEC_ERROR_ADDING_CERT: Error adding certificate to database.
  [root@f27-2 ~]# echo $?
  255

At this point I make an educated guess that because there is already
a certificate stored with the nickname ``IPA.LOCAL IPA CA``, it
refuses to add *another* CA certificate with a different Subject DN
under the same nickname.  So I will delete the certificates with
this nickname from the NSSDBs and try again.

TODO
