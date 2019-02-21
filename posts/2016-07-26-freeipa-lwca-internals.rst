---
tags: freeipa, dogtag, certificates, internals
---

..
  Copyright 2016 Red Hat, Inc.

  This work is licensed under a
  Creative Commons Attribution 4.0 International License.

  You should have received a copy of the license along with this
  work. If not, see <http://creativecommons.org/licenses/by/4.0/>.


FreeIPA Lightweight CA internals
================================

In the `preceding post`_, I explained the use cases for the FreeIPA
*lightweight sub-CAs* feature, how to manage CAs and use them to
issue certificates, and current limitations.  In this post I detail
some of the internals of how the feature works, including how
signing keys are distributed to replicas, and how sub-CA certificate
renewal works.  I conclude with a brief retrospective on delivering
the feature.

Full details of the design of the feature can be found `on the
design page`_.  This post does not cover everything from the design
page, but we will look at the aspects that are covered from the
perspective of the system administrator, i.e. *"what is happening on
my systems?"*

.. _preceding post: 2016-07-25-freeipa-subcas.html
.. _on the design page: http://www.freeipa.org/page/V4/Sub-CAs


Dogtag lightweight CA creation
------------------------------

The PKI system used by FreeIPA is called *Dogtag*.  It is a separate
project with its own interfaces; most FreeIPA certificate
management features are simply reflecting a subset of the
corresponding Dogtag interface, often integrating some additional
access controls or identity management concepts.  This is certainly
the case for FreeIPA sub-CAs.  The Dogtag lightweight CAs feature
was implemented initially to support the FreeIPA use case, yet not
all aspects of the Dogtag feature are used in FreeIPA as of v4.4,
and other consumers of the Dogtag feature are likely to emerge (in
particular: OpenStack).

The Dogtag lightweight CAs feature `has its own design page`_ which
documents the feature in detail, but it is worth mentioning some
important aspects of the Dogtag feature and their impact on how
FreeIPA uses the feature.

.. _has its own design page: http://pki.fedoraproject.org/wiki/Lightweight_sub-CAs

- Dogtag lightweight CAs are managed via a REST API.  The FreeIPA
  framework uses this API to create and manage lightweight CAs,
  using the privileged *RA Agent* certificate to authenticate.  In a
  future release we hope to remove the RA Agent and authenticate as
  the FreeIPA user using GSS-API proxy credentials.

- Each CA in a Dogtag instance, including the "main" CA, has an LDAP
  entry with object class ``authority``.  The schema includes fields
  such as subject and issuer DN, certificate serial number, and a
  UUID primary key, which is randomly generated for each CA.  When
  FreeIPA creates a CA, it stores this UUID so that it can map the
  FreeIPA CA's common name (CN) to the Dogtag authority ID in
  certificate requests or other management operations (e.g. CA
  deletion).

- The "nickname" of the lightweight CA signing key and certificate
  in Dogtag's NSSDB is the nickname of the "main" CA signing key,
  with the lightweight CA's UUID appended.  In general operation
  FreeIPA does not need to know this, but the ``ipa-certupdate``
  program has been enhanced to set up Certmonger tracking requests
  for FreeIPA-managed lightweight CAs and therefore it needs to know
  the nicknames.

- Dogtag lightweight CAs may be nested, but FreeIPA as of v4.4 does
  not make use of this capability.

So, let's see what actually happens on a FreeIPA server when we add
a lightweight CA.  We will use the ``sc`` example from the previous
post.  The command executed to add the CA, with its output, was::

  % ipa ca-add sc --subject "CN=Smart Card CA, O=IPA.LOCAL" \
      --desc "Smart Card CA"
  ---------------
  Created CA "sc"
  ---------------
    Name: sc
    Description: Smart Card CA
    Authority ID: 660ad30b-7be4-4909-aa2c-2c7d874c84fd
    Subject DN: CN=Smart Card CA,O=IPA.LOCAL
    Issuer DN: CN=Certificate Authority,O=IPA.LOCAL 201606201330


The LDAP entry added to the Dogtag database was::

  dn: cn=660ad30b-7be4-4909-aa2c-2c7d874c84fd,ou=authorities,ou=ca,o=ipaca
  authoritySerial: 63
  objectClass: authority
  objectClass: top
  cn: 660ad30b-7be4-4909-aa2c-2c7d874c84fd
  authorityID: 660ad30b-7be4-4909-aa2c-2c7d874c84fd
  authorityKeyNickname: caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d87
   4c84fd
  authorityKeyHost: f24b-0.ipa.local:443
  authorityEnabled: TRUE
  authorityDN: CN=Smart Card CA,O=IPA.LOCAL
  authorityParentDN: CN=Certificate Authority,O=IPA.LOCAL 201606201330
  authorityParentID: d3e62e89-df27-4a89-bce4-e721042be730

We see the authority UUID in the ``authorityID`` attribute as well
as ``cn`` and the DN.  ``authorityKeyNickname`` records the nickname
of the signing key in Dogtag's NSSDB.  ``authorityKeyHost`` records
which hosts possess the signing key - currently just the host on
which the CA was created.  ``authoritySerial`` records the serial
number of the certificate (more that that later).  The meaning of
the rest of the fields should be clear.

If we have a peek into Dogtag's NSSDB, we can see the new CA's
certificate::

  # certutil -d /etc/pki/pki-tomcat/alias -L

  Certificate Nickname              Trust Attributes
                                    SSL,S/MIME,JAR/XPI

  caSigningCert cert-pki-ca         CTu,Cu,Cu
  auditSigningCert cert-pki-ca      u,u,Pu
  Server-Cert cert-pki-ca           u,u,u
  caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd u,u,u
  ocspSigningCert cert-pki-ca       u,u,u
  subsystemCert cert-pki-ca         u,u,u

There it is, alongside the main CA signing certificate and other
certificates used by Dogtag.  The trust flags ``u,u,u`` indicate
that the private key is also present in the NSSDB.  If we pretty
print the certificate we will see a few interesting things::

  # certutil -d /etc/pki/pki-tomcat/alias -L \
      -n 'caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd'
  Certificate:
      Data:
          Version: 3 (0x2)
          Serial Number: 63 (0x3f)
          Signature Algorithm: PKCS #1 SHA-256 With RSA Encryption
          Issuer: "CN=Certificate Authority,O=IPA.LOCAL 201606201330"
          Validity:
              Not Before: Fri Jul 15 05:46:00 2016
              Not After : Tue Jul 15 05:46:00 2036
          Subject: "CN=Smart Card CA,O=IPA.LOCAL"
          ...
          Signed Extensions:
              ...
              Name: Certificate Basic Constraints
              Critical: True
              Data: Is a CA with no maximum path length.
              ...

Observe that:

- The certificate is indeed a CA.

- The serial number (``63``) agrees with the CA's LDAP entry.

- The validity period is 20 years, the default for CAs in Dogtag.
  This cannot be overridden on a per-CA basis right now, but
  addressing this is a priority.


Finally, let's look at the raw entry for the CA in the FreeIPA
database::

  dn: cn=sc,cn=cas,cn=ca,dc=ipa,dc=local
  cn: sc
  ipaCaIssuerDN: CN=Certificate Authority,O=IPA.LOCAL 201606201330
  objectClass: ipaca
  objectClass: top
  ipaCaSubjectDN: CN=Smart Card CA,O=IPA.LOCAL
  ipaCaId: 660ad30b-7be4-4909-aa2c-2c7d874c84fd
  description: Smart Card CA

We can see that this entry also contains the subject and issuer DNs,
and the ``ipaCaId`` attribute holds the Dogtag authority ID, which
allows the FreeIPA framework to dereference the local ID (``sc``) to
the Dogtag ID as needed.  We also see that the ``description``
attribute is local to FreeIPA; Dogtag also has a ``description``
attribute for lightweight CAs but FreeIPA uses its own.


Lightweight CA replication
--------------------------

FreeIPA servers replicate objects in the FreeIPA directory among
themselves, as do Dogtag replicas (note: in Dogtag, the term *clone*
is often used).  All Dogtag instances in a replicated environment
need to observe changes to lightweight CAs (creation, modification,
deletion) that were performed on another replica and update their
own view so that they can respond to requests consistently.  This is
accomplished via an LDAP *persistent search* which is run in an
*authority monitor* thread.  Care was needed to avoid race
conditions.  Fortunately, the solution for LDAP-based profile
storage provided a fine starting point for the authority monitor;
although lightweight CAs are more complex, many of the same race
conditions can occur and these were already addressed in the LDAP
profile monitor implementation.

But unlike LDAP-based profiles, a lightweight CA consists of more
than just an LDAP object; there is also the signing key.  The
signing key lives in Dogtag's NSSDB and for security reasons cannot
be transported through LDAP.  This means that when a Dogtag clone
observes the addition of a lightweight CA, an out-of-band mechanism
to transport the signing key must also be triggered.

This mechanism is covered in the design pages but the summarised
process is:

1. A Dogtag clone observes the creation of a CA on another server
   and starts a ``KeyRetriever`` thread.  The ``KeyRetriever`` is
   implemented as part of Dogtag, but it is configured to run the
   ``/usr/libexec/ipa/ipa-pki-retrieve-key`` program, which is
   part of FreeIPA.  The program is invoked with arguments of
   the server to request the key from (this was stored in the
   ``authorityKeyHost`` attribute mentioned earlier), and the
   nickname of the key to request.

2. ``ipa-pki-retrieve-key`` requests the key from the *Custodia*
   daemon on the source server.  It authenticates as the
   ``dogtag/<requestor-hostname>@REALM`` service principal.  If
   authenticated and authorised, the Custodia daemon exports the
   signing key from Dogtag's NSSDB **wrapped by the main CA's
   private key**, and delivers it to the requesting server.
   ``ipa-pki-retrieve-key`` outputs the wrapped key then exits.

3. The ``KeyRetriever`` reads the wrapped key and imports
   (*unwraps*) it into the Dogtag clone's NSSDB.  It then
   initialises the Dogtag CA's *Signing Unit* allowing the CA to
   service signing requests on that clone, and adds its own hostname
   to the CA's ``authorityKeyHost`` attribute.

Some excerpts of the CA debug log *on the clone* (not the server on
which the sub-CA was first created) shows this process in action.
The CA debug log is found at ``/var/log/pki/pki-tomcat/ca/debug``.
Some irrelevant messages have been omitted.

::

  [25/Jul/2016:15:45:56][authorityMonitor]: authorityMonitor: Processed change controls.
  [25/Jul/2016:15:45:56][authorityMonitor]: authorityMonitor: ADD
  [25/Jul/2016:15:45:56][authorityMonitor]: readAuthority: new entryUSN = 109
  [25/Jul/2016:15:45:56][authorityMonitor]: CertificateAuthority init 
  [25/Jul/2016:15:45:56][authorityMonitor]: ca.signing Signing Unit nickname caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd
  [25/Jul/2016:15:45:56][authorityMonitor]: SigningUnit init: debug Certificate object not found
  [25/Jul/2016:15:45:56][authorityMonitor]: CA signing key and cert not (yet) present in NSSDB
  [25/Jul/2016:15:45:56][authorityMonitor]: Starting KeyRetrieverRunner thread

Above we see the ``authorityMonitor`` thread observe the addition of
a CA.  It adds the CA to its internal map and attempts to initialise
it, which fails because the key and certificate are not available,
so it starts a ``KeyRetrieverRunner`` in a new thread.

::

  [25/Jul/2016:15:45:56][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: Running ExternalProcessKeyRetriever
  [25/Jul/2016:15:45:56][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: About to execute command: [/usr/libexec/ipa/ipa-pki-retrieve-key, caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd, f24b-0.ipa.local]

The ``KeyRetrieverRunner`` thread invokes ``ipa-pki-retrieve-key``
with the nickname of the key it wants, and a host from which it can
retrieve it.  If a CA has multiple sources, the
``KeyRetrieverRunner`` will try these in order with multiple
invocations of the helper, until one succeeds.  If none succeed, the
thread goes to sleep and retries when it wakes up initially after 10
seconds, then backing off exponentially.

::

  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: Importing key and cert
  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: Reinitialising SigningUnit
  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: ca.signing Signing Unit nickname caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd
  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: Got token Internal Key Storage Token by name
  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: Found cert by nickname: 'caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd' with serial number: 63
  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: Got private key from cert
  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: Got public key from cert
  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: in init - got CA name CN=Smart Card CA,O=IPA.LOCAL

The key retriever successfully returned the key data and import
succeeded.  The signing unit then gets initialised.

::

  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: Adding self to authorityKeyHosts attribute
  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: In LdapBoundConnFactory::getConn()
  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: postCommit: new entryUSN = 361
  [25/Jul/2016:15:47:13][KeyRetrieverRunner-660ad30b-7be4-4909-aa2c-2c7d874c84fd]: postCommit: nsUniqueId = 4dd42782-4a4f11e6-b003b01c-c8916432
  [25/Jul/2016:15:47:14][authorityMonitor]: authorityMonitor: Processed change controls.
  [25/Jul/2016:15:47:14][authorityMonitor]: authorityMonitor: MODIFY
  [25/Jul/2016:15:47:14][authorityMonitor]: readAuthority: new entryUSN = 361
  [25/Jul/2016:15:47:14][authorityMonitor]: readAuthority: known entryUSN = 361
  [25/Jul/2016:15:47:14][authorityMonitor]: readAuthority: data is current

Finally, the Dogtag clone adds itself to the CA's
``authorityKeyHosts`` attribute.  The ``authorityMonitor`` observes
this change but ignores it because its view is current.


Certificate renewal
-------------------

CA signing certificates will eventually expire, and therefore
require renewal.  Because the FreeIPA framework operates with low
privileges, it cannot add a Certmonger tracking request for sub-CAs
when it creates them.  Furthermore, although the renewal (i.e. the
actual signing of a new certificate for the CA) should only happen
on one server, the certificate must be updated in the NSSDB of all
Dogtag clones.

As mentioned earlier, the ``ipa-certupdate`` command has been
enhanced to add Certmonger tracking requests for FreeIPA-managed
lightweight CAs.  The actual renewal will only be performed on
whichever server is the *renewal master* when Certmonger decides it
is time to renew the certificate (assuming that the tracking request
has been added on that server).

Let's run ``ipa-certupdate`` on the renewal master to add the
tracking request for the new CA.  First observe that the tracking
request does not exist yet::

  # getcert list -d /etc/pki/pki-tomcat/alias |grep subject
          subject: CN=CA Audit,O=IPA.LOCAL 201606201330
          subject: CN=OCSP Subsystem,O=IPA.LOCAL 201606201330
          subject: CN=CA Subsystem,O=IPA.LOCAL 201606201330
          subject: CN=Certificate Authority,O=IPA.LOCAL 201606201330
          subject: CN=f24b-0.ipa.local,O=IPA.LOCAL 201606201330

As expected, we do not see our sub-CA certificate above.  After
running ``ipa-certupdate`` the following tracking request appears::

  Request ID '20160725222909':
          status: MONITORING
          stuck: no
          key pair storage: type=NSSDB,location='/etc/pki/pki-tomcat/alias',nickname='caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd',token='NSS Certificate DB',pin set
          certificate: type=NSSDB,location='/etc/pki/pki-tomcat/alias',nickname='caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd',token='NSS Certificate DB'
          CA: dogtag-ipa-ca-renew-agent
          issuer: CN=Certificate Authority,O=IPA.LOCAL 201606201330
          subject: CN=Smart Card CA,O=IPA.LOCAL
          expires: 2036-07-15 05:46:00 UTC
          key usage: digitalSignature,nonRepudiation,keyCertSign,cRLSign
          pre-save command: /usr/libexec/ipa/certmonger/stop_pkicad
          post-save command: /usr/libexec/ipa/certmonger/renew_ca_cert "caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd"
          track: yes
          auto-renew: yes

As for updating the certificate in each clone's NSSDB, Dogtag itself
takes care of that.  All that is required is for the renewal master
to update the CA's ``authoritySerial`` attribute in the Dogtag
database.  The ``renew_ca_cert`` Certmonger post-renewal hook script
performs this step.  Each Dogtag clone observes the update (in
the monitor thread), looks up the certificate with the indicated
serial number in its *certificate repository* (a new entry that will
also have been recently replicated to the clone), and adds that
certificate to its NSSDB.  Again, let's observe this process by
forcing a certificate renewal::

  # getcert resubmit -i 20160725222909
  Resubmitting "20160725222909" to "dogtag-ipa-ca-renew-agent".

After about 30 seconds the renewal process is complete.  When we
examine the certificate in the NSSDB we see, as expected, a new
serial number::

  # certutil -d /etc/pki/pki-tomcat/alias -L \
      -n "caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd" \
      | grep -i serial
          Serial Number: 74 (0x4a)

We also see that the ``renew_ca_cert`` script has updated the serial in
Dogtag's database::

  # ldapsearch -D cn="Directory Manager" -w4me2Test -b o=ipaca \
      '(cn=660ad30b-7be4-4909-aa2c-2c7d874c84fd)' authoritySerial
  dn: cn=660ad30b-7be4-4909-aa2c-2c7d874c84fd,ou=authorities,ou=ca,o=ipaca
  authoritySerial: 74

Finally, if we look at the CA debug log *on the clone*, we'll see
that the the *authority monitor* observes the serial number change
and updates the certificate in its own NSSDB (again, some irrelevant
or low-information messages have been omitted)::

  [26/Jul/2016:10:43:28][authorityMonitor]: authorityMonitor: Processed change controls.
  [26/Jul/2016:10:43:28][authorityMonitor]: authorityMonitor: MODIFY
  [26/Jul/2016:10:43:28][authorityMonitor]: readAuthority: new entryUSN = 1832
  [26/Jul/2016:10:43:28][authorityMonitor]: readAuthority: known entryUSN = 361
  [26/Jul/2016:10:43:28][authorityMonitor]: CertificateAuthority init 
  [26/Jul/2016:10:43:28][authorityMonitor]: ca.signing Signing Unit nickname caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd
  [26/Jul/2016:10:43:28][authorityMonitor]: Got token Internal Key Storage Token by name
  [26/Jul/2016:10:43:28][authorityMonitor]: Found cert by nickname: 'caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd' with serial number: 63
  [26/Jul/2016:10:43:28][authorityMonitor]: Got private key from cert
  [26/Jul/2016:10:43:28][authorityMonitor]: Got public key from cert
  [26/Jul/2016:10:43:28][authorityMonitor]: CA signing unit inited
  [26/Jul/2016:10:43:28][authorityMonitor]: in init - got CA name CN=Smart Card CA,O=IPA.LOCAL
  [26/Jul/2016:10:43:28][authorityMonitor]: Updating certificate in NSSDB; new serial number: 74

When the authority monitor processes the change, it reinitialises
the CA including its signing unit.  Then it observes that the serial
number of the certificate in its NSSDB differs from the serial
number from LDAP.  It pulls the certificate with the new serial
number from its certificate repository, imports it into NSSDB, then
reinitialises the signing unit once more and sees the correct serial
number::

  [26/Jul/2016:10:43:28][authorityMonitor]: ca.signing Signing Unit nickname caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd
  [26/Jul/2016:10:43:28][authorityMonitor]: Got token Internal Key Storage Token by name
  [26/Jul/2016:10:43:28][authorityMonitor]: Found cert by nickname: 'caSigningCert cert-pki-ca 660ad30b-7be4-4909-aa2c-2c7d874c84fd' with serial number: 74
  [26/Jul/2016:10:43:28][authorityMonitor]: Got private key from cert
  [26/Jul/2016:10:43:28][authorityMonitor]: Got public key from cert
  [26/Jul/2016:10:43:28][authorityMonitor]: CA signing unit inited
  [26/Jul/2016:10:43:28][authorityMonitor]: in init - got CA name CN=Smart Card CA,O=IPA.LOCAL

Currently this update mechanism is only used for lightweight CAs,
but it would work just as well for the main CA too, and we plan to
switch at some stage so that the process is consistent for all CAs.


Wrapping up
-----------

I hope you have enjoyed this tour of some of the lightweight CA
internals, and in particular seeing how the design actually plays
out on your systems in the real world.

FreeIPA lightweight CAs has been the most complex and challenging
project I have ever undertaken.  It took the best part of a year
from early design and proof of concept, to implementing the Dogtag
lightweight CAs feature, then FreeIPA integration, and numerous bug
fixes, refinements or outright redesigns along the way.  Although
there are still some rough edges, some important missing features
and, I expect, many an RFE to come, I am pleased with what has been
delivered and the overall design.

Thanks are due to all of my colleagues who contributed to the design
and review of the feature; each bit of input from all of you has
been valuable.  I especially thank Ade Lee and Endi Dewata from the
Dogtag team for their help with API design and many code reviews
over a long period of time, and from the FreeIPA team Jan Cholasta
and Martin Babinsky for a their invaluable input into the design,
and much code review and testing.  I could not have delivered this
feature without your help; thank you for your collaboration!
