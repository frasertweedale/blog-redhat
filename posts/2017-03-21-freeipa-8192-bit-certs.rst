Supporting large key sizes in FreeIPA certificates
==================================================

A couple of issues around key sizes in FreeIPA certificates have
come to my attention this week: how to issue certificates for large
key sizes, and how to deploy FreeIPA with a 4096-bit key.  In this
post I'll discuss the situation with each of these issues.  Though
related, they are different issues so I'll address each separately.

Issuing certificates with large key sizes
-----------------------------------------

While researching the second issue I stumbled across
issue `#6319: ipa cert-request limits key size to
1024,2048,3072,4096 bits <https://pagure.io/freeipa/issue/6319>`__.
To wit::

  ftweedal% ipa cert-request alice-8192.csr --principal alice
  ipa: ERROR: Certificate operation cannot be completed:
    Key Parameters 1024,2048,3072,4096 Not Matched

The solution is straightforward.  Each certificate profile
configures the key types and sizes that will be accepted by that
profile.  The default profile is configured to allow up to 4096-bit
keys, so the certificate request containing an 8192-bit key fails.
The profile configuration parameter involved is::

  policyset.<name>.<n>.constraint.params.keyParameters=1024,2048,3072,4096

If you append ``8192`` to that list and update the profile
configuration via ``ipa certprofile-mod`` (or create a new profile
via ``ipa certprofile-import``), then everything will work!


Deploying FreeIPA with IPA CA signing key > 2048-bits
-----------------------------------------------------

When you deploy FreeIPA today, the IPA CA has a 2048-bit RSA key.
There is currently no way to change this, but Dogtag does support
configuring the key size when spawning a CA instance, so it should
not be hard to support this in FreeIPA.  I created issue `#6790
<https://pagure.io/freeipa/issue/6790>`__ to track this.

Looking beyond RSA, there is also issue `#3951: ECC Support for the
CA <https://pagure.io/freeipa/issue/3951>`__ which concerns
supporting a elliptic curve signing key in the FreeIPA CA.  Once
again, Dogtag supports EC signing algorithms, so supporting this in
FreeIPA should be a matter of deciding the ``ipa-server-install(1)``
options and mechanically adjusting the ``pkispawn`` configuration.

If you have use cases for large signing keys and/or NIST ECC keys or
other algorithms, please do not hesitate to leave comments in the
issues linked above, or get in touch with the FreeIPA team on the
``freeipa-users@redhat.com`` mailing list or ``#freeipa`` on
Freenode.
