---
tags: dogtag, renewal, troubleshooting, freeipa
---

Offline expired certificate renewal for Dogtag
==============================================

The worst has happened.  Somehow, certificate renewal didn't happen
when it should have, and now you have expired certificates.  Worst,
these are Dogtag system certificates; you can't even start Dogtag to
issue new ones!  Unfortunately, this situation arises fairly often.
Sometimes due to administrator error or extended downtime; sometimes
due to bugs.  These cases are notoriously difficult (and expensive)
to analyse and resolve.  It often involves *time travel*:

1. Set the system clock to a time setting just before certificates
   started expiring.

2. Fix whatever caused renewal not to work in the first place.

3. Renew expiring certificates.

4. Reset system clock.

That is the *simple* case!  I have seen much gnarlier scenarios.
Ones where *multiple times* must be visited.  Ones where there is
*no time* at which all relevant certs are valid.

It would be nice to avoid these scenarios, and the FreeIPA team
continues to work to improve the robustness of certificate renewal.
We also have a monitoring / health check solution on the roadmap, so
that failure of automated renewal sets off alarms before *everything
else* falls over.  But in the meantime, customers and support are
still dealing with scenarios like this.  Better recovery tools are
needed.

And better tools are on the way!  Dinesh, one of the Dogtag
developers, has built a tool to simplify renewal when your Dogtag CA
is offline due to expired system certificates.  This post outlines
what the tool is, what it does, and my first experiences using it in
a FreeIPA deployment.  Along the way and especially toward the end
of the post, I will discuss the caveats and potential areas for
improvement, and FreeIPA-specific considerations.

``pki-server cert-fix``
-----------------------

The tool is implemented as a subcommand of the ``pki-server``
utility–namely ``cert-fix`` (and I will use this short name
throughout the post).  So it is implemented in Python, but in some
places it calls out to ``certutil`` or the Java parts of Dogtag via
the HTTP API.  The `user documentation`_ is maintained the source
repository.

.. _user documentation: https://github.com/dogtagpki/pki/blob/master/docs/admin/Offline_System_Certificate_Renewal.md

The insight at the core of ``cert-fix`` is that even if Dogtag is
not running or *cannot* run, we still have access to the keys needed
to issue certificates.  We *do* need to use Dogtag to properly store
issued certificates (for revocation purposes) and produce an audit
trail.  But if needed, we can use the CA signing key to
**temporarily** fudge the important certificates to get Dogtag
running again, then re-issue expired system certificates properly.

Assumptions
^^^^^^^^^^^

``cert-fix`` makes the following assumptions about your environment.
If these do not hold, then ``cert-fix``, as currently implemented,
cannot do its thing.

- The CA signing certificate is valid.

- You have a valid admin or agent certificate.  In a FreeIPA
  environment the ``IPA RA`` certificaite fulfils this role.

- (indirect) The LDAP server (389 DS) is operational, its
  certificate is valid, and Dogtag can authenticate to it.

These assumptions have been made for good reasons, but there are
several certificate expiry scenarios that breach them.  I will
discuss in detail later in the post.  For now, we must accept them.

What ``cert-fix`` does
^^^^^^^^^^^^^^^^^^^^^^

The ``cert-fix`` performs the following actions to renew an expired
system certificate:

#. Inspect the system and identify which system certificates need
   renewing.  Or the certificates can be specified on the command
   line.

#. If Dogtag's HTTPS certificate is expired, use certutil commands
   to issue a new "temporary" certificate.  The validity period is
   three months (from the current time).  The serial number of the
   current (expired) HTTPS is reused (a big X.509 no-no, but
   operationally no big deal in this scenario).  There is no audit
   trail and the certificate will not appear in the LDAP database.

#. Disable the startup self-test for affected subsystems, then start
   Dogtag.

#. For each target certificate, renew the certificate via API, using
   given credential.  Validity periods and other characteristics are
   determined by relevant profiles.  Serial numbers are chosen in
   the usual manner, the certificates appear in LDAP and there is an
   audit trail.

#. Stop Dogtag.

#. For each target certificate, import the new certificate into
   Dogtag's NSSDB.

#. Re-enable self-test for affected subsystems and start Dogtag.


Using ``cert-fix``
------------------

There are a couple of ways to try out the tool—without waiting for
certificates to expire, that is.  One way is to roll your system
clock forward, beyond the expiry date of one or more certificates.
Another possibility is to modify a certificate profile used for a
system certificate so that it will be issued with a very short
validity period.

I opted for the latter option.  I manually edited the default
profile configuration, so that Dogtag's OCSP and HTTPS certificates
would be issued with a validity period of 15 minutes.  By the time I
installed FreeIPA, grabbed a coffee and read a few emails, the
certificates had expired.  Certmonger didn't even attempt to renew
them.  Dogtag was still running and working properly, but ``ipactl
restart`` put Dogtag, and the whole FreeIPA deployment, out of
action.

I used ``pki-server cert-find`` to have a peek at Dogtag's system
certificates::

  [root@f29-0 ca]# pki-server cert-find
    Cert ID: ca_signing
    Nickname: caSigningCert cert-pki-ca
    Serial Number: 0x1
    Subject DN: CN=Certificate Authority,O=IPA.LOCAL 201902271325
    Issuer DN: CN=Certificate Authority,O=IPA.LOCAL 201902271325
    Not Valid Before: Wed Feb 27 14:30:22 2019
    Not Valid After: Mon Feb 27 14:30:22 2034

    Cert ID: ca_ocsp_signing
    Nickname: ocspSigningCert cert-pki-ca
    Serial Number: 0x2
    Subject DN: CN=OCSP Subsystem,O=IPA.LOCAL 201902271325
    Issuer DN: CN=Certificate Authority,O=IPA.LOCAL 201902271325
    Not Valid Before: Wed Feb 27 14:30:24 2019
    Not Valid After: Wed Feb 27 14:45:24 2019

    Cert ID: sslserver
    Nickname: Server-Cert cert-pki-ca
    Serial Number: 0x3
    Subject DN: CN=f29-0.ipa.local,O=IPA.LOCAL 201902271325
    Issuer DN: CN=Certificate Authority,O=IPA.LOCAL 201902271325
    Not Valid Before: Wed Feb 27 14:30:24 2019
    Not Valid After: Wed Feb 27 14:45:24 2019

    Cert ID: subsystem
    Nickname: subsystemCert cert-pki-ca
    Serial Number: 0x4
    Subject DN: CN=CA Subsystem,O=IPA.LOCAL 201902271325
    Issuer DN: CN=Certificate Authority,O=IPA.LOCAL 201902271325
    Not Valid Before: Wed Feb 27 14:30:24 2019
    Not Valid After: Tue Feb 16 14:30:24 2021

    Cert ID: ca_audit_signing
    Nickname: auditSigningCert cert-pki-ca
    Serial Number: 0x5
    Subject DN: CN=CA Audit,O=IPA.LOCAL 201902271325
    Issuer DN: CN=Certificate Authority,O=IPA.LOCAL 201902271325
    Not Valid Before: Wed Feb 27 14:30:24 2019
    Not Valid After: Tue Feb 16 14:30:24 2021

Note the ``Not Valid After`` times for the ``ca_ocsp_signing`` and
``sslserver`` certificates.  These are certificates we must renew.

Preparing the agent certificate
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The ``cert-fix`` command requires an agent certificate.  We will use
the *IPA RA* certificate.  The ``pki-server`` CLI tool needs an
NSSDB with the agent key and certificate.  So we have to set that
up.  First initialise the NSSDB::

  [root@f29-0 ~]# mkdir ra-nssdb
  [root@f29-0 ~]# cd ra-nssdb
  [root@f29-0 ra-nssdb]# certutil -d . -N
  Enter a password which will be used to encrypt your keys.
  The password should be at least 8 characters long,
  and should contain at least one non-alphabetic character.

  Enter new password: XXXXXXXX
  Re-enter password: XXXXXXXX

Then create a PKCS #12 file containing the required key and
certificates::

  [root@f29-0 ra-nssdb]# openssl pkcs12 -export \
    -inkey /var/lib/ipa/ra-agent.key \
    -in /var/lib/ipa/ra-agent.pem \
    -name "ra-agent" \
    -certfile /etc/ipa/ca.crt > ra-agent.p12
  Enter Export Password:
  Verifying - Enter Export Password:

Import it into the NSSDB, and fix up trust flags on the IPA CA
certificate::

  [root@f29-0 ra-nssdb]# pk12util -d . -i ra-agent.p12
  Enter Password or Pin for "NSS Certificate DB":
  Enter password for PKCS12 file:
  pk12util: PKCS12 IMPORT SUCCESSFUL

  [root@f29-0 ra-nssdb]# certutil -d . -L

  Certificate Nickname                                         Trust Attributes
                                                               SSL,S/MIME,JAR/XPI

  ra-agent                                                     u,u,u
  Certificate Authority - IPA.LOCAL 201902271325               ,,

  [root@f29-0 ra-nssdb]# certutil -d . -M \
      -n 'Certificate Authority - IPA.LOCAL 201902271325' \
      -t CT,C,C
  Enter Password or Pin for "NSS Certificate DB":

  [root@f29-0 ra-nssdb]# certutil -d . -L

  Certificate Nickname                                         Trust Attributes
                                                               SSL,S/MIME,JAR/XPI

  ra-agent                                                     u,u,u
  Certificate Authority - IPA.LOCAL 201902271325               CT,C,C


Running ``cert-fix``
^^^^^^^^^^^^^^^^^^^^

Let's look at the ``cert-fix`` command options::

  [root@f29-0 ra-nssdb]# pki-server cert-fix --help
  Usage: pki-server cert-fix [OPTIONS]

        --cert <Cert ID>            Fix specified system cert (default: all certs).
    -i, --instance <instance ID>    Instance ID (default: pki-tomcat).
    -d <NSS database>               NSS database location (default: ~/.dogtag/nssdb)
    -c <NSS DB password>            NSS database password
    -C <path>                       Input file containing the password for the NSS database.
    -n <nickname>                   Client certificate nickname
    -v, --verbose                   Run in verbose mode.
        --debug                     Run in debug mode.
        --help                      Show help message.

It's not a good idea to put passphrases on the command line in the
clear, so let's write the NSSDB passphrase to a file::

  [root@f29-0 ra-nssdb]# cat > pwdfile.txt
  XXXXXXXX
  ^D

Finally, I was ready to execute ``cert-fix``::

  [root@f29-0 ra-nssdb]# pki-server cert-fix \
      -d . -C pwdfile.txt -n ra-agent \
      --cert sslserver --cert ca_ocsp_signing \
      --verbose

Running with ``--verbose`` causes ``INFO`` and higher-level log
messages to be printed to the terminal.  Running with ``--debug``
includes ``DEBUG`` messages.  If neither of these is used, *nothing*
is output (unless there's an error).  So I recommend running with
``--verbose``.

So, what happened?  Unfortunately I ran into several issues.

389 DS not running
~~~~~~~~~~~~~~~~~~

The first issue was trivial, but likely to occur if you have to
``cert-fix`` a FreeIPA deployment.  The ``ipactl [re]start`` command
will shut down *every* component if *any* component failed to start.
Dogtag didn't start, therefore ``ipactl`` shut down 389 DS too.  As
a consequence, Dogtag failed to initialise after ``cert-fix``
started it, and the command failed.

So, before running ``cert-fix``, make sure LDAP is working properly.
To start it, use ``systemctl`` instead of ``ipactl``::

  # systemctl start dirsrv@YOUR-REALM

Connection refused
~~~~~~~~~~~~~~~~~~

One issue I encountered was that a slow startup of Dogtag caused
failure of the tool.  ``cert-fix`` does not wait for Dogtag to start
up properly.  It just ploughs ahead—only to encounter
``ConnectionRefusedError``.

I worked around this—temporarily—by adding a sleep after
``cert-fix`` starts Dogtag.  A proper fix will require a change to
the code.  ``cert-fix`` should perform a server status check,
retrying until it succeeds or times out.

TLS handshake failure
~~~~~~~~~~~~~~~~~~~~~

The next error I encountered was a TLS handshake failure::

  urllib3.exceptions.MaxRetryError:
    HTTPSConnectionPool(host='f29-0.ipa.local', port=8443): Max retries
    exceeded with url: /ca/rest/certrequests/profiles/caManualRenewal
    (Caused by SSLError(SSLError(185073780, '[X 509: KEY_VALUES_MISMATCH]
    key values mismatch (_ssl.c:3841)')))

I haven't worked out yet what is causing this surprising error.  But
I wasn't the first to encounter it.  A `comment in the Bugzilla
ticket`_ indicated that the workaround was to *remove* the IPA CA
certificate from the client NSSDB.  This I did::

  [root@f29-0 ra-nssdb]# certutil -d . -D \
      -n "Certificate Authority - IPA.LOCAL 201902271325"

After this, my next attempt at running ``cert-fix`` succeeded.

.. _comment in the Bugzilla ticket: https://bugzilla.redhat.com/show_bug.cgi?id=1669257#c10


Results
^^^^^^^

Looking at the previously expired target certificates, observe that
the certificates have been updated.  They have new serial numbers,
and expire in 15 months::

  [root@f29-0 ra-nssdb]# certutil -d /etc/pki/pki-tomcat/alias \
      -L -n 'Server-Cert cert-pki-ca' | egrep "Serial|Not After"
        Serial Number: 12 (0xc)
            Not After : Wed May 27 12:45:25 2020

  [root@f29-0 ra-nssdb]# certutil -d /etc/pki/pki-tomcat/alias \
      -L -n 'ocspSigningCert cert-pki-ca' | egrep "Serial|Not After"
        Serial Number: 13 (0xd)
            Not After : Wed May 27 12:45:28 2020

Looking at the output of ``getcert list`` for the target
certificates, we see that Certmonger has *not* picked these up (some
lines removed)::

  [root@f29-0 ra-nssdb]# getcert list -i 20190227033149
  Number of certificates and requests being tracked: 9.
  Request ID '20190227033149':
     status: CA_UNREACHABLE
     ca-error: Internal error
     stuck: no
     CA: dogtag-ipa-ca-renew-agent
     issuer: CN=Certificate Authority,O=IPA.LOCAL 201902271325
     subject: CN=OCSP Subsystem,O=IPA.LOCAL 201902271325
     expires: 2019-02-27 14:45:24 AEDT
     eku: id-kp-OCSPSigning

  [root@f29-0 ra-nssdb]# getcert list -i 20190227033152
  Number of certificates and requests being tracked: 9.
  Request ID '20190227033152':
     status: CA_UNREACHABLE
     ca-error: Internal error
     stuck: no
     CA: dogtag-ipa-ca-renew-agent
     issuer: CN=Certificate Authority,O=IPA.LOCAL 201902271325
     subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201902271325
     expires: 2019-02-27 14:45:24 AEDT
     dns: f29-0.ipa.local
     key usage: digitalSignature,keyEncipherment,dataEncipherment
     eku: id-kp-serverAuth

Restarting Certmonger (``systemctl restart certmonger``) resolved
the discrepancy.

Finally, ``ipactl restart`` puts everything back online.
``cert-fix`` has saved the day!

::

  [root@f29-0 ra-nssdb]# ipactl restart
  Restarting Directory Service
  Starting krb5kdc Service
  Starting kadmin Service
  Starting httpd Service
  Starting ipa-custodia Service
  Starting pki-tomcatd Service
  Starting ipa-otpd Service
  ipa: INFO: The ipactl command was successful



Issues and caveats
------------------

Besides the issues already covered, there are several scenarios that
``cert-fix`` cannot handle.


Expired CA certificate
^^^^^^^^^^^^^^^^^^^^^^

Due to the the long validity period of a typical CA certificate, the
assumption that the CA certificate is valid is the safest assumption
made by ``cert-fix``.  But it is not a safe assumption.

The most common way this assumption is violated is with
externally-signed CA certificates.  For example, the FreeIPA CA in
your organisation is signed by Active Directory CA, with a validity
period of two years.  Things get overlooked and suddenly, your
FreeIPA CA is expired.  It may take some time for the upstream CA
administrators to issue a new certificate.  In the meantime, you
want to get your FreeIPA/Dogtag CA back up.

Right now ``cert-fix`` doesn't handle this scenario.  I think it
should.  As far as I can tell, this should be straightforward to
support.  Unlike the next few issues…


Agent certificate expiry
^^^^^^^^^^^^^^^^^^^^^^^^

This concerns the assumption that you have a valid agent
certificate.  Dogtag requires authentication to perform privilieged
operations like certificate issuance.  Also, the authenticated user
must be included in audit events.  ``cert-fix`` *must* issue
certificates properly (with limiited temporary fudging tolerated for
operational efficacy), therefore there *must* be an agent
credential.  And if your agent credential is a certificate, it
*must* be valid.  So if your agent certificate is expired, it's
Catch-22.  That is why the tool, as currently implemented, must
assume you have a valid, non-expired agent certificate.

In some deployments the agent certificate is renewed on a different
cadence from subsystem certificates.  In that case, this scenario is
less like to occur—but still entirely possible!  The assumption is
bad.

In my judgement it is fairly important to find a workaround for
this.  One idea could be to talk directly to LDAP and set a
randomly-generated password on an agent account, and use that to
authenticate.  After the tool exits, the passphrase is forgotten.
This approach means ``cert-fix`` needs a credential and privileges
to perform those operations in LDAP.

Speaking of LDAP...


389 DS certificate authentication
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

In FreeIPA deployments, Dogtag is configured to use the subsystem
certificate to bind (authenticate) to the LDAP server.  If the
subsystem certificate is expired, 389 DS will reject the
certificate; the connection fails and and Dogtag cannot start.

A workaround for this may be to temporarily reconfigure Dogtag to
use a password to authenticate to LDAP.  Then after the new
subsystem certificate was issued, it must be added to the
``pkidbuser`` entry in LDAP, and certificate authentication
reinstated.

This is not a FreeIPA-specific consideration.  Using TLS client
authentication to bind to LDAP is a supported configuration in
Dogtag / RHCS.  So we should probably support it in ``cert-fix``
too, somehow, since the point of the tool is to avoid complex manual
procedures in recovering from expired system certificates.


389 DS service certificate expiry
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

You know the tune by now… if this certificate is expired, Dogtag
can't talk to LDAP and can't start, therefore a new LDAP certificate
can't be issued.

Issuing a temporary certificate with the same serial number may be
the best way forward here, like what we do for the Dogtag HTTPS
certificate.


Re-keying
^^^^^^^^^

…is not supported.  But it is a possible future enhancement


Serial number reuse
^^^^^^^^^^^^^^^^^^^

Re-using a serial number is prohibited by the X.509 standard.
Although the temporary re-issued HTTPS certificate is supposed to be
temporary, what if it did leak out?  For example, another client
that contacted Dogtag while that certificate is in use could log it
to a Certificate Transparency log (not a public one, unless your
Dogtag CA is chained to a publicly trusted CA).  If this occurred,
there would be a record that the CA had misbehaved.

What are the ramifications?  If this happened in the public PKI, the
offending CA would *at best* get a harsh and very public
admonishment, and be put on notice.  But trust store vendors might
just straight up wash their hands of you and yank trust.

In a private PKI is it such a big deal?  Given our use case—the same
subject names are used—probably not.  But I leave it as an open
topic to ponder how this might backfire.


Conclusion
----------

In this post I introduced the ``pki-server cert-fix`` subcommand.
The purpose of this tool is to simplify and speed up recovery when
Dogtag system certificates have expired.

It does what it says on the tin, with a few rough edges and, right
now, a lot of caveats.  The fundamentals are very good, but I think
we need to address number of these caveats for ``cert-fix`` to be
generally useful, especially in a FreeIPA context.  Based on my
early experiences and investigation, my suggested priorities are:

#. Workaround for when the agent certificate is expired.  This can
   affect every kind of deployment and the reliance on a valid agent
   certificate is a significant limitation.

#. Workaround for expired subsystem certificate when TLS client
   authentication is used to bind to LDAP.  This affects all FreeIPA
   deployments (standalone Dogtag deployments less commonly).

#. Support renewing the CA certificate in ``cert-fix``.  A degree of
   sanity checking or confirmation may be reasonable (e.g. it must
   be explicitly listed on the CLI as a ``--cert`` option).

#. Investigate ways to handle expired LDAP certificate, if issued by
   Dogtag.  In some deployments, including some FreeIPA deployments,
   the LDAP certificate is not issued by Dogtag, so the risk is not
   universal.

In writing this post I by no means wish to diminish Dinesh's work.
On the contrary, I'm impressed with what the tool already can do!
And, mea culpa, I have taken far too long to test this tool and
evaluate it in a FreeIPA setting.  Now that I have a clearer
picture, I see that I will be very busy making the tool more capable
and ready for action in FreeIPA scenarios.
