---
tags: acme, certificates, freeipa
---

Introducing the FreeIPA ACME service
====================================

*This post is part of a series of ACME client demonstrations. See
also the posts about*
`mod_md for Apache`_
*and*
`Certbot with FreeIPA DNS`_.

.. _mod_md for Apache: 2020-05-07-ipa-acme-mod_md.html
.. _Certbot with FreeIPA DNS: 2020-05-13-ipa-acme-dns.html

*Automated Certificate Management Environment (ACME)* is a protocol
for automated identifier validation and certificate issuance.  Its
goal is to improve security on the Internet by reducing certificate
lifetimes and avoiding manual processes from certificate lifecycle
management.

ACME's original use case is HTTPS on the public Internet.  The
public CA `*Let's Encrypt*`_ is already one of the biggest CAs.
Clients use ACME to talk to *Let's Encrypt*, automating DNS name
validation, certificate issuance and in most cases, certificate
installation and renewal.

But ACME is not limited to Let's Encrypt.  Other CAs implement it
and enterprise (private) CAs can implement it too.  And after a few
years of talking about it, we are finally implementing an ACME
service in FreeIPA.

In this post I will give a high-level overview of the ACME protocol,
and the ACME service architecture in FreeIPA.  If that doesn't
interest you, scroll down to the demo where I show the Certbot ACME
client acquiring a certificate from the FreeIPA CA.

.. _*Let's Encrypt*: https://letsencrypt.org/


ACME protocol, in brief
-----------------------

1. ACME client registers with ACME server.  ACME accounts *may* be
   bound to some external accounts but more commonly clients
   register *ad hoc* with no binding to any other service.  This is
   the case for the FreeIPA ACME service.

2. ACME client creates an *order* for a certificate with one or more
   *identifiers* (e.g. DNS names).  The FreeIPA ACME service
   initially supports only DNS identifiers, but the IETF ACME
   working has defined challenges for other identifier types
   including IP addresses and email addresses.

3. ACME service offers *challenges* that the client can use to prove
   *control* of the identifier.  For DNS names there are three
   challenge types:

   ``dns-01``
     Client creates DNS records to prove control of the identifier.
   ``http-01`` 
     Client provisions HTTP resource to prove control of the
     identifier.
   ``tls-alpn-01``
     Client configures TLS server use *Application Layer Protocol
     Negotiation (ALPN)* and a special X.509 certificate to prove
     control of the identifier.

   The FreeIPA ACME service currently implements the ``dns-01`` and
   ``http-01`` challenges.

4. Client responds to the challenge and advises ACME server to
   proceed with validation.

5. Server attempts to validate the clients response to the
   challenge.  The identifier is *authorised* when sufficient
   challenges (usually one per identifier) have been validated.

6. After all identifiers in the order have been authorised, the
   client *finalises* the order causing the CA to issue the
   certificate.

7. The client retrieves the issued certificate and (commonly)
   configures an application to use it.

There are many ACME client implementations.  Some, such as
`Certbot`_, are general purpose and can be used standalone or
integrated with many kinds of applications.  Others are application
specific, like `mod_md`_ for Apache httpd.

.. _Certbot: https://certbot.eff.org/
.. _mod_md: https://httpd.apache.org/docs/current/mod/mod_md.html


FreeIPA ACME service architecture
---------------------------------

The FreeIPA ACME service uses `Dogtag PKI ACME responder`_.  This is
an optional component of Dogtag, separate from the CA or other
subsystems.  Like other Dogtag subsystems it run in the same process
and is accessed via Tomcat.

.. _Dogtag PKI ACME responder: https://www.dogtagpki.org/wiki/PKI_ACME_Responder

The Dogtag ACME subsystem will automatically be deployed on every CA
server in a FreeIPA deployment.  But **it will not service
requests** until the administrator enables it.  There are two
reasons for this approach.

For ease of client configuration it is desired to have a single,
permanent name for the ACME service across the whole topology.  The
topology should be able to evolve without having the reconfigure
ACME clients.  There is already a candidate DNS name that is either
managed by FreeIPA (when using internal DNS) or required to managed
by administrators (when not using internal DNS).  That is
``ipa-ca.$DOMAIN``.  This points to all CA replicas in the topology.
If we let administrators choose the FreeIPA servers upon which to
configure the ACME service, we would have to introduce a new DNS
name to manage.  It will complicate code, and impose a new burden on
administrators if the internal DNS is not used.  By automatically
deploying the ACME service on all CA replicas, the
``ipa-ca.$DOMAIN`` name is always a valid name for ACME clients to
use.

The second reason is that there is just less for adminstrators to
worry about.  How do I install the ACME service?  Don't worry about
it, it's already there, just turn it on.

Turning the ACME service on or off, or other configuration changes,
will be effected deployment-wide.  At least, that is the goal.
Early releases *might* require per-server configuration steps.  But
eventually configuration will be contained in the replicated LDAP
database and administrators will just use regular ``ipa``
subcommands to control the ACME service deployment-wide.

The ACME database, too, will be replicated deployment wide.  It is
possible that some data, such as *nonces*, might have to be kept
server-local for performance reasons (this is not the case now, but
load testing is coming).


Demo: Certbot client running standalone HTTP server
---------------------------------------------------

The following demo scenario was carried out on a FreeIPA-enrolled
host.  The ACME protocol requires the use of TLS between client and
server.  The FreeIPA ACME service certificate is (usually) signed by
the FreeIPA CA, so the client needs to trust it.  On machines that
are not FreeIPA clients CA trust would have to be established by
other means so that the ACME client will trust the ACME server.

The general purpose ACME client `Certbot`_ integrates with many
different server program and can also be used "standalone".  That is
what I will do in this demo.  It is not representative of real-world
use but is a straightforward way to demonstrate that an ACME server is
operating correctly.

The two steps, registration and issuance, can be rolled into a
single command.  For clarity I will keep these as two separate
steps.

Registration
^^^^^^^^^^^^

First, the registration step creates an account with the ACME
service::

  [root@f31-0 ~]# certbot \
      --server https://ipa-ca.ipa.local/acme/directory \
      register -m ftweedal@redhat.com \
      --agree-tos --no-eff-email
  Saving debug log to /var/log/letsencrypt/letsencrypt.log

  - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  Would you be willing to share your email address with the Electronic Frontier
  Foundation, a founding partner of the Let's Encrypt project and the non-profit
  organization that develops Certbot? We'd like to send you email about our work
  encrypting the web, EFF news, campaigns, and ways to support digital freedom.
  - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  (Y)es/(N)o: n

  IMPORTANT NOTES:
   - Your account credentials have been saved in your Certbot
     configuration directory at /etc/letsencrypt. You should make a
     secure backup of this folder now. This configuration directory will
     also contain certificates and private keys obtained by Certbot so
     making regular backups of this folder is ideal.

By default Certbot will contact *Let's Encrypt*, the public CA.  The
``--server`` option is given to point Certbot to the FreeIPA ACME
service instead.

``-m`` gives a contact email address (this is optional).
``--agree-tos`` agrees to the terms of service of the ACME server.
``--no-eff-email`` suppresses the "share email with EFF" prompt
(which is only relevant when using Let's Encrypt anyway).

Identifier validation and certificate issuance
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

and ACME account then request a certificate for the machine's
hostname from the FreeIPA CA.


The next step is to issue the certificate.  The ``certonly`` command
means: just write the issued certificate to disk; don't configure
any programs to use it.  The ``--domain`` option can be given
multiple times to request a certificate with multiple subject
alternative names.

The ``--standalone`` option tells Certbot to start its own HTTP
server to fulfil the ``http-01`` challenge.  This server will listen
on ``tcp/80`` therefore it must run as ``root``.  In typical
production scenarios Certbot will instead integrate with existing
HTTP servers and avoid running it with ``root`` privileges.  Or you
would use an alternative client implementation suited to your use
case.

::

  [root@f31-0 ~]# certbot \
      --server https://ipa-ca.ipa.local/acme/directory \
      certonly \
      --key-type rsa \
      --domain $(hostname) \
      --standalone
  Saving debug log to /var/log/letsencrypt/letsencrypt.log
  Plugins selected: Authenticator standalone, Installer None
  Obtaining a new certificate
  Performing the following challenges:
  http-01 challenge for f31-0.ipa.local
  Waiting for verification...
  Cleaning up challenges

  IMPORTANT NOTES:
   - Congratulations! Your certificate and chain have been saved at:
     /etc/letsencrypt/live/f31-0.ipa.local/fullchain.pem
     Your key file has been saved at:
     /etc/letsencrypt/live/f31-0.ipa.local/privkey.pem
     Your cert will expire on 2020-08-03. To obtain a new or tweaked
     version of this certificate in the future, simply run certbot
     again. To non-interactively renew *all* of your certificates, run
     "certbot renew"
   - If you like Certbot, please consider supporting our work by:

     Donating to ISRG / Let's Encrypt:   https://letsencrypt.org/donate
     Donating to EFF:                    https://eff.org/donate-le

The whole command completed in a few seconds.  Below is the pretty
print of the certificate.  Observe the ~3 month validity and that
the issuer is the FreeIPA CA, not Let's Encrypt.

::

  [root@f31-0 ~]# openssl x509 -text -noout -in /etc/letsencrypt/live/f31-0.ipa.local/cert.pem
  Certificate:
    Data:
    Version: 3 (0x2)
    Serial Number: 25 (0x19)
    Signature Algorithm: sha256WithRSAEncryption
    Issuer: O = IPA.LOCAL 202004011654, CN = Certificate Authority
    Validity
        Not Before: May  5 11:30:33 2020 GMT
        Not After : Aug  3 11:30:33 2020 GMT
    Subject: CN = f31-0.ipa.local
    Subject Public Key Info:
        Public Key Algorithm: rsaEncryption
            RSA Public-Key: (2048 bit)
            Modulus:
                <snip>
            Exponent: 65537 (0x10001)
    X509v3 extensions:
        X509v3 Subject Key Identifier: 
            2D:75:79:C2:A0:8C:EF:44:D2:6B:E4:19:E6:BC:42:23:BA:66:1E:D9
        X509v3 Authority Key Identifier: 
            keyid:5E:55:7C:10:82:C1:19:09:E2:42:EC:65:96:89:08:50:35:62:FE:8F

        X509v3 Subject Alternative Name: 
            DNS:f31-0.ipa.local
        X509v3 Key Usage: critical
            Digital Signature, Key Encipherment
        X509v3 Extended Key Usage: 
            TLS Web Server Authentication, TLS Web Client Authentication
        Authority Information Access: 
            OCSP - URI:http://ipa-ca.ipa.local/ca/ocsp

        X509v3 CRL Distribution Points: 

            Full Name:
              URI:http://ipa-ca.ipa.local/ipa/crl/MasterCRL.bin
            CRL Issuer:
              DirName:O = ipaca, CN = Certificate Authority

    Signature Algorithm: sha256WithRSAEncryption
         <snip>


Discussion
----------

In this post I demonstrated just one basic client scenario.  In
upcoming posts I will explore some more advanced and more realistic
client scenarios including use of the DNS-based challenges and the
`mod_md`_ client module for Apache httpd.

The Dogtag ACME responder and FreeIPA ACME service are still
undergoing rapid development and are **not production ready**.  Some
parts of the Dogtag implementation have made their way into
releases, but should be considered a "preview".  That said, if you
would like to play with the ACME service or perform integration
testing, we are happy to collaborate and you should reach out on
``pki-devel@redhat.com``.

The fact that ACME accounts have no "binding" to any existing
FreeIPA may surprise some people.  In the initial release we want to
implement the "baseline" use case also addressed by the public ACME
CAs (Let's Encrypt).  That is: *an essentially anonymous client
proves control of an identifier and gets a certificate.*  We
recognise that organisiations *may* want ACME accounts to be
associated with (or views of) existing identities, and implement
authorisation policies based on those accounts and their groups.
But we don't *know* whether this is required, or exactly what it
would look like.  So we are going to "wait and see" if customers
tell us what "enterprise ACME" should be.  In the mean time we are
focused on the core use case.

Other considerations for the FreeIPA ACME service include:

- customising the ACME certificate profile (e.g. altering the
  validity period, Certificate Policies extension, etc)

- issuing ACME certificates from a sub-CA of the FreeIPA CA

- controlling which validation challenges are enabled

- block/allow lists or other mechanisms to decide whether a
  particular identifier (DNS name) can be issued via ACME

All of these are on the roadmap, but they are likely to be deferred
beyond the initial release.

Conclusion
----------

That's all for this post.  I'll be following up soon with a post
about using Apache mod_md_ with the FreeIPA ACME service.
