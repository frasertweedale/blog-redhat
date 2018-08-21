Issuing suborindate CA certificates from FreeIPA
================================================

FreeIPA, since version 4.4, has supported creating subordinate CAs
within the deployment's Dogtag CA instance.  This feature is called
`lightweight sub-CAs <2016-07-25-freeipa-subcas.html>`_.  But what
about when you need to issue a subordinate CA certificate to an
external entity?  One use case would be chaining a FreeIPA
deployment up to some existing FreeIPA deployment.  This is similar
to what many customers do with Active Directory.  In this post I'll
show how you can issue subordinate CA certificates from FreeIPA.

Scenario description
--------------------

The existing FreeIPA deployment has the realm ``IPA.LOCAL`` and
domain ``ipa.local``.  Its CA's *Subject Distinguished Name (Subject
DN)* is ``CN=Certificate Authority,O=IPA.LOCAL 201808022359``.  The
master's hostname is ``f28-0.ipa.local``.  I will refer to this
deployment as the *existing* or *primary deployment*.

I will install a new FreeIPA deployment on the host
``f28-1.ipa.local``, with realm ``SUB.IPA.LOCAL`` and domain
``sub.ipa.local``.  This will be called the *secondary deployment*.
Its CA will be signed by the CA of the primary deployment.

Choice of subject principal and Subject DN
------------------------------------------

All certificate issuance via FreeIPA (with some limited exceptions)
requires a nominated *subject principal*.  Subject names in the CSR
(Subject DN and *Subject Alternative Names*) are validated against
the subject principal.  We must create a subject principal in the
primary deployment to represent the CA of the secondary deployment.

When validating CSRs, the *Common Name (CN)* of the Subject DN is
checked against the subject principal, in the following ways:

- for *user* principals, the CN must match the UID

- for *host* principals, the CN must match the hostname
  (case-insensitive)

- for *service* principals, the CN must match the hostname
  (case-insensitive); only principal aliases with the same service
  type as the canonical principal are checked

This validation regime imposes a restriction on what the CN of the
subordinate CA can be.  In particular:

- the Subject DN must contain a CN attribute

- the CN value can be a hostname (host or service principal), or a
  UID (user principal)

For this scenario, I chose to create a host principal for the domain
of the secondary deployment::

  [f28-0]% ipa host-add --force sub.ipa.local
  --------------------------
  Added host "sub.ipa.local"
  --------------------------
    Host name: sub.ipa.local
    Principal name: host/sub.ipa.local@IPA.LOCAL
    Principal alias: host/sub.ipa.local@IPA.LOCAL
    Password: False
    Keytab: False
    Managed by: sub.ipa.local


Creating a certificate profile for sub-CAs
------------------------------------------

We will tweak the ``caIPAserviceCert`` profile configuration to
create a new profile for subordinate CAs.  Export the profile
configuration::

  [f28-0]% ipa certprofile-show caIPAserviceCert --out SubCA.cfg
  ------------------------------------------------
  Profile configuration stored in file 'SubCA.cfg'
  ------------------------------------------------
    Profile ID: caIPAserviceCert
    Profile description: Standard profile for network services
    Store issued certificates: TRUE

Perform the following edits to ``SubCA.cfg``:

#. Replace ``profileId=caIPAserviceCert`` with ``profileId=SubCA``.

#. Replace the ``subjectNameDefaultImpl`` component with the
   ``userSubjectNameDefaultImpl`` component.  This will use the
   Subject DN from the CSR *as is*, without restriction::

    policyset.serverCertSet.1.constraint.class_id=noConstraintImpl
    policyset.serverCertSet.1.constraint.name=No Constraint
    policyset.serverCertSet.1.default.class_id=userSubjectNameDefaultImpl
    policyset.serverCertSet.1.default.name=Subject Name Default

#. Edit the ``keyUsageExtDefaultImpl`` and
   ``keyUsageExtConstraintImpl`` configurations.  They should have
   the following settings:

   - ``keyUsageCrlSign=true``
   - ``keyUsageDataEncipherment=false``
   - ``keyUsageDecipherOnly=false``
   - ``keyUsageDigitalSignature=true``
   - ``keyUsageEncipherOnly=false``
   - ``keyUsageKeyAgreement=false``
   - ``keyUsageKeyCertSign=true``
   - ``keyUsageKeyEncipherment=false``
   - ``keyUsageNonRepudiation=true``

#. Add the *Basic Constraints* extension configuration::

    policyset.serverCertSet.15.constraint.class_id=basicConstraintsExtConstraintImpl
    policyset.serverCertSet.15.constraint.name=Basic Constraint Extension Constraint
    policyset.serverCertSet.15.constraint.params.basicConstraintsCritical=true
    policyset.serverCertSet.15.constraint.params.basicConstraintsIsCA=true
    policyset.serverCertSet.15.constraint.params.basicConstraintsMinPathLen=0
    policyset.serverCertSet.15.constraint.params.basicConstraintsMaxPathLen=0
    policyset.serverCertSet.15.default.class_id=basicConstraintsExtDefaultImpl
    policyset.serverCertSet.15.default.name=Basic Constraints Extension Default
    policyset.serverCertSet.15.default.params.basicConstraintsCritical=true
    policyset.serverCertSet.15.default.params.basicConstraintsIsCA=true
    policyset.serverCertSet.15.default.params.basicConstraintsPathLen=0

   Add the new components' index to the component list, to ensure
   they get processed::

    policyset.serverCertSet.list=1,2,3,4,5,6,7,8,9,10,11,12,15

#. Remove the ``commonNameToSANDefaultImpl`` and *Extended Key
   Usage* related components.  This can be accomplished by removing
   the relevant indices (in my case, ``7`` and ``12``) from the
   component list::

    policyset.serverCertSet.list=1,2,3,4,5,6,8,9,10,11,15

#. (*Optional*) edit the validity period in the
   ``validityDefaultImpl`` and ``validityConstraintImpl``
   components.  The default is 731 days.  I did not change it.

For the avoidance of doubt, the diff between the
``caIPAserviceCert`` profile configuration and ``SubCA`` is::

  --- caIPAserviceCert.cfg        2018-08-21 12:44:01.748884778 +1000
  +++ SubCA.cfg   2018-08-21 14:05:53.484698688 +1000
  @@ -13,5 +13,3 @@
  -policyset.serverCertSet.1.constraint.class_id=subjectNameConstraintImpl
  -policyset.serverCertSet.1.constraint.name=Subject Name Constraint
  -policyset.serverCertSet.1.constraint.params.accept=true
  -policyset.serverCertSet.1.constraint.params.pattern=CN=[^,]+,.+
  -policyset.serverCertSet.1.default.class_id=subjectNameDefaultImpl
  +policyset.serverCertSet.1.constraint.class_id=noConstraintImpl
  +policyset.serverCertSet.1.constraint.name=No Constraint
  +policyset.serverCertSet.1.default.class_id=userSubjectNameDefaultImpl
  @@ -19 +16,0 @@
  -policyset.serverCertSet.1.default.params.name=CN=$request.req_subject_name.cn$, o=IPA.LOCAL 201808022359
  @@ -66,2 +63,2 @@
  -policyset.serverCertSet.6.constraint.params.keyUsageCrlSign=false
  -policyset.serverCertSet.6.constraint.params.keyUsageDataEncipherment=true
  +policyset.serverCertSet.6.constraint.params.keyUsageCrlSign=true
  +policyset.serverCertSet.6.constraint.params.keyUsageDataEncipherment=false
  @@ -72,2 +69,2 @@
  -policyset.serverCertSet.6.constraint.params.keyUsageKeyCertSign=false
  -policyset.serverCertSet.6.constraint.params.keyUsageKeyEncipherment=true
  +policyset.serverCertSet.6.constraint.params.keyUsageKeyCertSign=true
  +policyset.serverCertSet.6.constraint.params.keyUsageKeyEncipherment=false
  @@ -78,2 +75,2 @@
  -policyset.serverCertSet.6.default.params.keyUsageCrlSign=false
  -policyset.serverCertSet.6.default.params.keyUsageDataEncipherment=true
  +policyset.serverCertSet.6.default.params.keyUsageCrlSign=true
  +policyset.serverCertSet.6.default.params.keyUsageDataEncipherment=false
  @@ -84,2 +81,2 @@
  -policyset.serverCertSet.6.default.params.keyUsageKeyCertSign=false
  -policyset.serverCertSet.6.default.params.keyUsageKeyEncipherment=true
  +policyset.serverCertSet.6.default.params.keyUsageKeyCertSign=true
  +policyset.serverCertSet.6.default.params.keyUsageKeyEncipherment=false
  @@ -111,2 +108,13 @@
  -policyset.serverCertSet.list=1,2,3,4,5,6,7,8,9,10,11,12
  -profileId=caIPAserviceCert
  +policyset.serverCertSet.15.constraint.class_id=basicConstraintsExtConstraintImpl
  +policyset.serverCertSet.15.constraint.name=Basic Constraint Extension Constraint
  +policyset.serverCertSet.15.constraint.params.basicConstraintsCritical=true
  +policyset.serverCertSet.15.constraint.params.basicConstraintsIsCA=true
  +policyset.serverCertSet.15.constraint.params.basicConstraintsMinPathLen=0
  +policyset.serverCertSet.15.constraint.params.basicConstraintsMaxPathLen=0
  +policyset.serverCertSet.15.default.class_id=basicConstraintsExtDefaultImpl
  +policyset.serverCertSet.15.default.name=Basic Constraints Extension Default
  +policyset.serverCertSet.15.default.params.basicConstraintsCritical=true
  +policyset.serverCertSet.15.default.params.basicConstraintsIsCA=true
  +policyset.serverCertSet.15.default.params.basicConstraintsPathLen=0
  +policyset.serverCertSet.list=1,2,3,4,5,6,8,9,10,11,15
  +profileId=SubCA

Now import the profile::

  [f28-0]% ipa certprofile-import SubCA \
              --desc "Subordinate CA" \
              --file SubCA.cfg \
              --store=1
  ------------------------
  Imported profile "SubCA"
  ------------------------
    Profile ID: SubCA
    Profile description: Subordinate CA
    Store issued certificates: TRUE


Creating the CA ACL
-------------------

Before issuing a certificate, *CA ACLs* are checked to determine if
the combination of CA, profile and subject principal is acceptable.
We must create a CA ACL that permits use of the ``SubCA`` profile to
issue certificate to our subject principal::

  [f28-0]% ipa caacl-add SubCA
  --------------------
  Added CA ACL "SubCA"
  --------------------
    ACL name: SubCA
    Enabled: TRUE

  [f28-0]% ipa caacl-add-profile SubCA --certprofile SubCA
    ACL name: SubCA
    Enabled: TRUE
    Profiles: SubCA
  -------------------------
  Number of members added 1
  -------------------------

  [f28-0]% ipa caacl-add-ca SubCA --ca ipa
    ACL name: SubCA
    Enabled: TRUE
    CAs: ipa
    Profiles: SubCA
  -------------------------
  Number of members added 1
  -------------------------

  [f28-0]% ipa caacl-add-host SubCA --hosts sub.ipa.local
    ACL name: SubCA
    Enabled: TRUE
    CAs: ipa
    Profiles: SubCA
    Hosts: sub.ipa.local
  -------------------------
  Number of members added 1
  -------------------------


Installing the secondary FreeIPA deployment
-------------------------------------------

We are finally ready to run ``ipa-server-install`` to set up the
secondary deployment.  We need to use the ``--ca-subject`` option to
override the default Subject DN that will be included in the CSR,
providing a valid DN according to the rules discussed above.

::

  [root@f28-1]# ipa-server-install \
      --realm SUB.IPA.LOCAL \
      --domain sub.ipa.local \
      --external-ca \
      --ca-subject 'CN=SUB.IPA.LOCAL,O=Red Hat'

  ...

  The IPA Master Server will be configured with:
  Hostname:       f28-1.ipa.local
  IP address(es): 192.168.124.142
  Domain name:    sub.ipa.local
  Realm name:     SUB.IPA.LOCAL

  The CA will be configured with:
  Subject DN:   CN=SUB.IPA.LOCAL,O=Red Hat
  Subject base: O=SUB.IPA.LOCAL
  Chaining:     externally signed (two-step installation)

  Continue to configure the system with these values? [no]: yes

  ...

  Configuring certificate server (pki-tomcatd). Estimated time: 3 minutes
    [1/8]: configuring certificate server instance

  The next step is to get /root/ipa.csr signed by your CA and re-run
  /usr/sbin/ipa-server-install as:
  /usr/sbin/ipa-server-install
    --external-cert-file=/path/to/signed_certificate
    --external-cert-file=/path/to/external_ca_certificate
  The ipa-server-install command was successful


Let's inspect ``/root/ipa.csr``::

  [root@f28-1]# openssl req -text < /root/ipa.csr |grep Subject:
          Subject: O = Red Hat, CN = SUB.IPA.LOCAL

The desired Subject DN appears in the CSR (note that ``openssl``
shows DN components in the opposite order from FreeIPA).  After
copying the CSR to ``f28-0.ipa.local`` we can request the
certificate::

  [f28-0]% ipa cert-request ~/ipa.csr \
              --principal host/sub.ipa.local \
              --profile SubCA \
              --certificate-out ipa.pem
    Issuing CA: ipa
    Certificate: MIIEAzCCAuugAwIBAgIBFTANBgkqhkiG9w0BAQsF...
    Subject: CN=SUB.IPA.LOCAL,O=Red Hat
    Issuer: CN=Certificate Authority,O=IPA.LOCAL 201808022359
    Not Before: Tue Aug 21 04:16:24 2018 UTC
    Not After: Fri Aug 21 04:16:24 2020 UTC
    Serial number: 21
    Serial number (hex): 0x15

The certificate was saved in the file ``ipa.pem``.  We can see from
the command output that the Subject DN in the certificate is exactly
what was in the CSR.  Further inspecting the certificate, observe
that the Basic Constraints extension is present and the Key Usage
extension contains the appropriate assertions::

  [f28-0]% openssl x509 -text < ipa.pem
  ...
        X509v3 extensions:
            ...
            X509v3 Key Usage: critical
                Digital Signature, Non Repudiation, Certificate Sign, CRL Sign
            ...
            X509v3 Basic Constraints: critical
                CA:TRUE, pathlen:0
            ...

Now, after copying the just-issued subordinate CA certificate and
the primary CA certificate (``/etc/ipa/ca.crt``) over to
``f28-1.ipa.local``, we can continue the installation::

  [root@f28-1]# ipa-server-install \
                  --external-cert-file ca.crt \
                  --external-cert-file ipa.pem

  The log file for this installation can be found in /var/log/ipaserver-install.log
  Directory Manager password: XXXXXXXX

  ...

  Adding [192.168.124.142 f28-1.ipa.local] to your /etc/hosts file
  Configuring ipa-custodia
    [1/5]: Making sure custodia container exists
  ...
  The ipa-server-install command was successful

And we're done.


Discussion
----------

I've shown how to create a profile for issuing subordinate CA
certificates in FreeIPA.  Because of the way FreeIPA validates
certificate requests—always against a subject principal—there are
restrictions on the what the subject DN of the subordinate CA can
be.  The Subject DN must contain a CN attribute matching either the
hostname of a host or service principal, or the UID of a user
principal.

If you want to avoid these Subject DN restrictions, right now there
is no choice but to use the Dogtag CA directly, instead of via the
FreeIPA commands.  If such a requirement emerges it might make sense
to implement some "special handling" for issuing sub-CA certificates
(similar to what we currently do for the KDC certificate).  But the
certificate request logic is already complicated; I am hesitant to
complicate it even more.

Currently there is no sub-CA profile included in FreeIPA by default.
It might make sense to include it, or at least to produce an
official solution document describing the procedure outlined in this
post.
