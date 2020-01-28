---
tags: certificates, freeipa, howto
---

Deploying FreeIPA with a 4096-bit CA signing key
================================================

Recent versions of FreeIPA create a 3072-bit CA signing key by
default.  Older versions used 2048-bit signing keys.  Until
recently, there was no supported way to deploy FreeIPA with a larger
signing key.  It was an open secret that you could hack a single
file to change the key size when deploying, and everything would
work just fine.  But still, it was not supported or recommended to
do this.

As of FreeIPA 4.8 (RHEL 8.1; Fedora 30) there is an officially
supported way to choose a different key size when installing
FreeIPA.  In this short post I will demonstrate how to do it.

First, an admonition.  Choosing a larger key size can negatively
affect performance, for both signing and verification (i.e. *all
clients are affected*).  4096-bit RSA operations are twice as slow
as 3072-bit RSA, but the bits of security grows at a smaller rate.
3072-bit RSA has 128 bits of security, but 4096-bit RSA only
increases your security to 140 bits.  For 256 bits of security you
need a 15360-bit key.  In practice 3072-bit RSA is expected to be
secure for at least another decade.

With that out of the way, let's look at how to do it.  The procedure
works for both self-signed and externally-signed CAs.  It is done
via the ``--pki-config-override`` option, which allows the server
administrator to specify a file that sets or overrides Dogtag
``pkispawn(8)`` configuration directives.  ``pki_default.cfg(5)``
gives a comprehensive overview of the directives available, although
not all of these are allowed to be overriden in a FreeIPA
installation (``ipa-server-install`` itself checks the file for
directives that are not allowed to be overridden).

Fortunately, override is allowed for the ``pki_ca_signing_key_size``
directive.  Setting this to 4096 (or some other sensible value) will
have the desired effect, as the following transcript demonstrates::

  [root@rhel82-0 ~]# cat > pki_override.cfg <<EOF
  [CA]
  pki_ca_signing_key_size=4096
  EOF

  [root@rhel82-0 ~]# ipa-server-install \
      --unattended \
      --realm IPA.LOCAL \
      --ds-password "$DM_PASS" --admin-password "$ADMIN_PASS" \
      --external-ca \
      --pki-config-override $PWD/pki_override.cfg

  ... stuff happens ...

    [1/10]: configuring certificate server instance
  The next step is to get /root/ipa.csr signed by your
  CA and re-run /usr/sbin/ipa-server-install as:
  /usr/sbin/ipa-server-install \
    --external-cert-file=/path/to/signed_certificate \
    --external-cert-file=/path/to/external_ca_certificate
  The ipa-server-install command was successful

  [root@rhel82-0 ~]# openssl req -text < /root/ipa.csr | head
  Certificate Request:
      Data:
          Version: 1 (0x0)
          Subject: O = IPA.LOCAL, CN = Certificate Authority
          Subject Public Key Info:
              Public Key Algorithm: rsaEncryption
                  RSA Public-Key: (4096 bit)
                  Modulus:
                      00:c6:05:36:7b:28:c6:03:19:19:91:d3:e9:31:28:
                      5f:50:ab:60:a4:e8:fa:09:ba:5d:a1:25:53:cf:74:

The key size is 4096-bit, as expected.  Had the ``--external-ca``
option *not* been provided a 4096-bit self-signed CA would have been
created and the installation would have run to completion.
