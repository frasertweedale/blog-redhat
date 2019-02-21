---
tags: freeipa, certificates
---

..
  Copyright 2016 Red Hat, Inc.

  This work is licensed under a
  Creative Commons Attribution 4.0 International License.

  You should have received a copy of the license along with this
  work. If not, see <http://creativecommons.org/licenses/by/4.0/>.


Lightweight Sub-CAs in FreeIPA 4.4
==================================

Last year FreeIPA 4.2 brought us some great new certificate
management features, including custom certificate profiles and user
certificates.  The upcoming FreeIPA 4.4 release builds upon this
groundwork and introduces *lightweight sub-CAs*, a feature that lets
admins to mint new CAs under the main FreeIPA CA and allows
certificates for different purposes to be issued in different
certificate domains.  In this post I will review the use cases and
demonstrate the process of creating, managing and issuing
certificates from sub-CAs.  (A follow-up post will detail some of
the mechanisms that operate behind the scenes to make the feature
work.)


Use cases
---------

Currently, all certificates issued by FreeIPA are issued by a single
CA.  Say you want to issue certificates for various purposes:
regular server certificates, and user certificates for VPN
authentication, and authentication to a particular web service.
Currently, assuming the certificate bore the appropriate Key Usage
and Extended Key Usages extensions (with the default profile, they
do), a certificate issued for one of these purposes could be used
for all of the other purposes.

Issuing certificates for particular purposes (especially client
authentication scenarios) from a sub-CA allows an administrator to
configure the endpoint authenticating the clients to use the
immediate issuer certificate for validation client certificates.
Therefore, if you had a sub-CA for issuing VPN authentication
certificates, and a different sub-CA for issuing certificates for
authenticating to the web service, one could configure these
services to accept certificates issued by the relevant CA only.
Thus, where previously the scope of usability may have been
unacceptably broad, administrators now have more fine-grained
control over how certificates can be used.

Finally, another important consideration is that while revoking the
main IPA CA is usually out of the question, it is now possible to
revoke an intermediate CA certificate.  If you create a CA for a
particular organisational unit (e.g. some department or working
group) or service, if or when that unit or service ceases to operate
or exist, the related CA certificate can be revoked, rendering
certificates issued by that CA useless, as long as relying endpoints
perform CRL or OCSP checks.


Creating and managing sub-CAs
-----------------------------

In this scenario, we will add a sub-CA that will be used to issue
certificates for users' smart cards.  We assume that a profile for
this purpose already exists, called ``userSmartCard``.

To begin with, we are authenticated as ``admin`` or another user
that has CA management privileges.  Let's see what CAs FreeIPA
already knows about::

  % ipa ca-find
  ------------
  1 CA matched
  ------------
    Name: ipa
    Description: IPA CA
    Authority ID: d3e62e89-df27-4a89-bce4-e721042be730
    Subject DN: CN=Certificate Authority,O=IPA.LOCAL 201606201330
    Issuer DN: CN=Certificate Authority,O=IPA.LOCAL 201606201330
  ----------------------------
  Number of entries returned 1
  ----------------------------

We can see that FreeIPA knows about the ``ipa`` CA.  This is the
"main" CA in the FreeIPA infrastructure.  Depending on how FreeIPA
was installed, it could be a root CA or it could be chained to an
external CA.  The ``ipa`` CA entry is added automatically when
installing or upgrading to FreeIPA 4.4.

Now, let's add a new sub-CA called ``sc``::

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

The ``--subject`` option gives the full Subject Distinguished Name
for the new CA; it is mandatory, and must be unique among CAs
managed by FreeIPA.  An optional description can be given with
``--desc``.  In the output we see that the Issuer DN is that of the
IPA CA.

Having created the new CA, we must add it to one or more *CA ACLs*
to allow it to be used.  CA ACLs were added in FreeIPA 4.2 for
defining policies about which profiles could be used for issuing
certificates to which *subject* principals (note: the subject
principal is not necessarily the principal performing the
certificate request).  In FreeIPA 4.4 the CA ACL concept has been
extended to also include which CA is being asked to issue the
certificate.

We will add a CA ACL called ``user-sc-userSmartCard`` and associate
it with all users, with the ``userSmartCard`` profile, and with the
``sc`` CA::

  % ipa caacl-add user-sc-userSmartCard --usercat=all
  ------------------------------------
  Added CA ACL "user-sc-userSmartCard"
  ------------------------------------
    ACL name: user-sc-userSmartCard
    Enabled: TRUE
    User category: all

  % ipa caacl-add-profile user-sc-userSmartCard --certprofile userSmartCard
    ACL name: user-sc-userSmartCard
    Enabled: TRUE
    User category: all
    CAs: sc
    Profiles: userSmartCard
  -------------------------
  Number of members added 1
  -------------------------

  % ipa caacl-add-ca user-sc-userSmartCard --ca sc
    ACL name: user-sc-userSmartCard
    Enabled: TRUE
    User category: all
    CAs: sc
  -------------------------
  Number of members added 1
  -------------------------

A CA ACL can reference multiple CAs individually, or, like we saw
with users above, we can associate a CA ACL with *all* CAs by
setting ``--cacat=all`` when we create the CA ACL, or via the ``ipa
ca-mod`` command.

A special behaviour of CA ACLs with respect to CAs must be
mentioned: if a CA ACL is associated with no CAs (either
individually or by category), then it allows access to the ``ipa``
CA (and only that CA).  This behaviour, though inconsistent with
other aspects of CA ACLs, is for compatibility with pre-sub-CAs CA
ACLs.  An alternative approach is being discussed and could be
implemented before the final release.


Requesting certificates from sub-CAs
------------------------------------

The ``ipa cert-request`` command has learned the ``--ca`` argument
for directing the certificate request to a particular sub-CA.  If it
is not given, it defaults to ``ipa``.

``alice`` already has a CSR for the key in her smart card, so now
she can request a certificate from the ``sc`` CA::

  % ipa cert-request --principal alice \
      --profile userSmartCard --ca sc /path/to/csr.req
    Certificate: MIIDmDCCAoCgAwIBAgIBQDANBgkqhkiG9w0BA...
    Subject: CN=alice,O=IPA.LOCAL
    Issuer: CN=Smart Card CA,O=IPA.LOCAL
    Not Before: Fri Jul 15 05:57:04 2016 UTC
    Not After: Mon Jul 16 05:57:04 2018 UTC
    Fingerprint (MD5): 6f:67:ab:4e:0c:3d:37:7e:e6:02:fc:bb:5d:fe:aa:88
    Fingerprint (SHA1): 0d:52:a7:c4:e1:b9:33:56:0e:94:8e:24:8b:2d:85:6e:9d:26:e6:aa
    Serial number: 64
    Serial number (hex): 0x40


Certmonger has also learned the ``-X``/``--issuer`` option for
specifying that the request be directed to the named issuer.  There
is a clash of terminology here; the "CA" terminology in Certmonger
is already used to refer to a particular CA "endpoint".  Various
kinds of CAs and multiple instances thereof are supported.  But now,
with Dogtag and FreeIPA, a single CA may actually host many CAs.
Conceptually this is similar to HTTP virtual hosts, with the ``-X``
option corresponding to the ``Host:`` header for disambiguating the
CA to be used.

If the ``-X`` option was given when creating the tracking request,
the Certmonger FreeIPA submit helper uses its value in the ``--ca``
option to ``ipa cert-request``.  These requests are subject to CA
ACLs.


Limitations
-----------

It is worth mentioning a few of the limitations of the sub-CAs
feature, as it will be delivered in FreeIPA 4.4.

All sub-CAs are signed by the ``ipa`` CA; there is no support for
"nesting" CAs.  This limitation is imposed by FreeIPA - the
lightweight CAs feature in Dogtag does not have this limitation.  It
could be easily lifted in a future release, if there is a demand for
it.

There is no support for introducing unrelated CAs into the
infrastructure, either by creating a new root CA or by importing an
unrelated external CA.  Dogtag does not have support for this yet,
either, but the lightweight CAs feature was designed so that this
would be possible to implement.  This is also why all the commands
and argument names mention "CA" instead of "Sub-CA".  I expect that
there will be demand for this feature at some stage in the future.

Currently, the key type and size are fixed at RSA 2048.  Same is
true in Dogtag, and this is a fairly high priority to address.
Similarly, the validity period is fixed, and we will need to address
this also, probably by allowing custom CA profiles to be used.


Conclusion
----------

The Sub-CAs feature will round out FreeIPA's certificate management
capabilities making FreeIPA a more attractive solution for
organisations with sophisticated certificate requirements.  Multiple
security domains can be created for issuing certificates with
different purposes or scopes.  Administrators have a simple
interface for creating and managing CAs and rules for how those CAs
can be used.

There are some limitations which may be addressed in a future
release; the ability to control key type/size and CA validity period
will be the highest priority among them.

This post examined the use cases and high-level user/administrator
experience of sub-CAs.  In the next post, I will detail some of the
machinery that makes the sub-CAs feature work.
