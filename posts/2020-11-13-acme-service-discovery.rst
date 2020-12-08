---
tags: acme, certificates, dns
---

ACME Service Discovery
======================

Automated Certificate Management Environment (ACME) is a protocol
for automated identifer validation certificate issuance.  Over the
past five years it gained widespread adoption thanks to `Let's
Encrypt`_, the first publicly trusted CA that implemented it.  ACME
is supported by a plethora of server programs and service providers,
Let's Encrypt has now issued over `1 billion certificates`_ and
together with the ACME protocol itself is largely responsible for
pushing the adoption of TLS from around 50% of page loads five years
ago to well over 80% today.  This is an amazing result!

.. _Let's Encrypt: https://letsencrypt.org/
.. _1 billion certificates: https://letsencrypt.org/2020/02/27/one-billion-certs.html

So it's no surprise that the ACME ecosystem is growing.  Some other
publicly trusted CAs now support the ACME protocol.  Enterprise CAs
are learning how to speak ACME.  This includes `Dogtag`_, and by
extension FreeIPA.  The upcoming FreeIPA 4.9 release will support
ACME (I `blogged about this`_ a few months ago).

Having proved itself good for DNS certificates, `RFC 8738`_
introduced supported for IP addresses.  Work to support email
addresses (for S/MIME), ``.onion`` addresses (Tor services), and
other identifer types is underway in the IETF `acme Working Group`_.
(ACME itself is defined in `RFC 8555`_).

.. _Dogtag: https://www.dogtagpki.org/wiki/ACME
.. _blogged about this: 2020-05-06-ipa-acme-intro.html
.. _acme Working Group: https://datatracker.ietf.org/wg/acme/documents/
.. _RFC 8555: https://tools.ietf.org/html/rfc8555
.. _RFC 8738: https://tools.ietf.org/html/rfc8738

The outcome of all of this is that already today, and increasingly
into the future, network environments will often have access to
multiple ACME servers.  These servers may differ in the kinds of
certificates they issue and the validation methods (also called
"challenge types") they support.  Also, it is desirable that a
client (e.g. a printer or an IoT "thing") would be able to
opportunistically and automatically locate a suitable ACME server to
acquire certificates without any operator (human or otherwise)
intervention (and Let's Encrypt or other public ACME servers may not
be accessible in some environments).

So, what's an ACME client to do?

Internet-Draft
--------------

I have `published an Internet-Draft`_ defining a service discovery
protocol for ACME.  *Internet-Draft* is IETF_ jargon for a
work-in-progress document that might one day become an RFC_.  An
outline of how ACME Service Discovery works follows.

.. _published an Internet-Draft: https://datatracker.ietf.org/doc/draft-tweedale-acme-discovery/
.. _IETF: https://www.ietf.org/
.. _RFC: https://www.ietf.org/standards/rfcs/

ACME Service Discovery is a profile of *DNS-based Service Discovery
(DNS-SD)* (`RFC 6763`_).  Given a *parent domain*, *Service Instance
Names* are listed by the PTR records of
``_acme-server._tcp.$PARENT``.  For example, the ``corp.example.``
parent domain advertises two service instances called ``CorpCA`` and
``C4A``::

    $ORIGIN corp.example.

    _acme-server._tcp PTR CorpCA._acme-server._tcp
    _acme-server._tcp PTR C4A._acme-server._tcp

.. _RFC 6763: https://tools.ietf.org/html/rfc6763


Each Service Instance Name owns an SRV and TXT record that together
describe the location, priority and capabilities of the server, as
well as the path to the ACME directory object.  Continuing with the
example, ``CorpCA`` has the higher priority and supports the ``ip``
and ``dns`` identifer types, whereas ``C4A`` has a lower priority
and only supports ``dns`` identifiers::

    $ORIGIN corp.example.

    CorpCA._acme-server._tcp SRV 10 0 443 ca
    CorpCA._acme-server._tcp TXT "path=/acme" "i=ip,dns"

    C4A._acme-server._tcp    SRV 20 0 443 certs4all.example.
    C4A._acme-server._tcp    TXT "path=/acme/v2" "i=dns"

ACME clients are assumed to know (or deduce) one or more candidate
parent domains.  Possible sources for the candidate parent domain(s)
are the DNS search domains, host FQDN or Kerberos realm.  The client
performs ACME Service Discovery on each parent domain, selecting and
probing eligible service instances, until they find one that works.
The probe step involves constructing a URL from the SRV target and
port and TXT ``path`` attribute, performing an HTTP GET request for
that resource, and checking that the response is a valid ACME
directory object.  In the example above, the directory URL for
``CorpCA`` is ``https://ca.corp.example/acme``.

And that's the main idea!  There's a fair bit more detail in the
Internet-Draft but I won't belabour it all here.


Enabling ACME Service Discovery in FreeIPA
------------------------------------------

To enable ACME Service Discovery in a FreeIPA environment using the
integrated DNS service, add the PTR, SRV and TXT records for each
service instance.  This requires a `recently merged patch`_ to allow
PTR records to be created in arbitrary zones (PTR records were
previously limited to ``.arpa`` reverse zones).  The fix should be
included in FreeIPA 4.9 and will also be backported to the 4.8.x
branch.

.. _recently merged patch: https://github.com/freeipa/freeipa/pull/5239

The following DNS records advertise the FreeIPA CA itself::

  % ipa dnsrecord-add ipa.local ipa._acme-server._tcp \
      --srv-priority 10 --srv-weight 0 \
      --srv-port 443 --srv-target ipa-ca \
      --txt-rec '"path=/acme/directory" "i=dns"'
    Record name: ipa._acme-server._tcp
    SRV record: 10 0 443 ipa-ca
    TXT record: "path=/acme/directory" "i=dns"

  % ipa dnsrecord-add ipa.local _acme-server._tcp \
      --ptr-rec "ipa._acme-server._tcp.ipa.local."
    Record name: _acme-server._tcp
    PTR record: ipa._acme-server._tcp.ipa.local.

The procedure to advertise additional ACME servers is similar.

If the ACME Service Discovery proposal gets traction we would
ideally create these records to advertise the FreeIPA CA
automatically (when it is enabled).

Certbot plugin
--------------

I wrote a Certbot_ plugin to experiment with service discovery.  It
lives in a private branch at
https://github.com/frasertweedale/certbot/tree/feature/discovery.  I
will probably submit a pull request soon, to invite feedback about
the implementation and the service disovery proposal itself.

.. _Certbot: https://certbot.eff.org/

To install Certbot and the plugin under ``~/.local/`` (command
output omitted)::

  # git clone https://github.com/certbot/certbot -b feature/discovery
  # cd certbot/certbot
  # pip install --user .
  # cd ../certbot-discovery
  # pip install --user .

Run ``certbot plugins`` to verify that the plugin is installed::

  # certbot plugins
  Saving debug log to /var/log/letsencrypt/letsencrypt.log

  - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  * discovery
  Description: ACME Service Discovery
  Interfaces: IPlugin
  Entry point: discovery = certbot_discovery:ACMEServiceDiscovery

  * standalone
  Description: Spin up a temporary webserver
  Interfaces: IAuthenticator, IPlugin
  Entry point: standalone = certbot._internal.plugins.standalone:Authenticator

  * webroot
  Description: Place files in webroot directory
  Interfaces: IAuthenticator, IPlugin
  Entry point: webroot = certbot._internal.plugins.webroot:Authenticator
  - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -


Now register an account with the ACME server.  Note the
``--discovery`` option::

  # certbot --discovery register \
    --email ftweedal@redhat.com \
    --agree-tos --no-eff-email
  Saving debug log to /var/log/letsencrypt/letsencrypt.log
  Account registered.

If service discovery fails, it will fail silently and use Let's
Encrypt (Certbot's default).  ``--discovery=force`` suppresses this
fallback behaviour; if service discovery fails Certbot will abort.

Next request the certificate::

  # certbot --discovery certonly \
      --domain $(hostname) --standalone
  Saving debug log to /var/log/letsencrypt/letsencrypt.log
  Plugins selected: Authenticator standalone, Installer None
  Obtaining a new certificate
  Performing the following challenges:
  http-01 challenge for f33-0.ipa.local
  Waiting for verification...
  Cleaning up challenges

  IMPORTANT NOTES:
   - Congratulations! Your certificate and chain have been saved at:
     /etc/letsencrypt/live/f33-0.ipa.local/fullchain.pem
     Your key file has been saved at:
     /etc/letsencrypt/live/f33-0.ipa.local/privkey.pem
     Your cert will expire on 2021-02-10. To obtain a new or tweaked
     version of this certificate in the future, simply run certbot
     again. To non-interactively renew *all* of your certificates, run
     "certbot renew"
   - If you like Certbot, please consider supporting our work by:

     Donating to ISRG / Let's Encrypt:   https://letsencrypt.org/donate
     Donating to EFF:                    https://eff.org/donate-le

We can check that the certificate was issued by the FreeIPA CA, not
Let's Encrypt::

  # openssl x509 -issuer -noout  \
      < /etc/letsencrypt/live/f33-0.ipa.local/fullchain.pem
  issuer=O = IPA.LOCAL 202011061623, CN = Certificate Authority

You do have to supply the ``--discovery`` option to both the
``register`` and ``certonly`` commands (otherwise ``certonly`` will
try to use Let's Encrypt).  Fortunately, for *renewal* (the
``renew`` command) Certbot does remember which server issued the
certificate, and uses the same server for renewal.

What happens when service discovery fails?  I'll disable the ACME
service on the FreeIPA server::

  % sudo ipa-acme-manage disable
  The ipa-acme-manage command was successful

Then, running ``certbot register`` again, this time with
``--discovery=force`` to prevent fallback to Let's Encrypt::

  # certbot --discovery=force register \
    --email ftweedal@redhat.com \
    --agree-tos --no-eff-email
  usage:
    certbot [SUBCOMMAND] [options] [-d DOMAIN] [-d DOMAIN] ...

  Certbot can obtain and install HTTPS/TLS/SSL certificates.  By default,
  it will attempt to use a webserver both for obtaining and installing the
  certificate.
  certbot: error: service discovery failed (see /tmp/tmp6qq8pnks for info)

The log file contains a transcript of the service discovery plugin's
activity::

  # cat /tmp/tmp6qq8pnks
  [INFO] processing parent domain ipa.local.
  [INFO] enumerating service instances for _acme-server._tcp.ipa.local.
  [INFO]   found service instances: [<DNS name ipa._acme-server._tcp.ipa.local.>]
  [INFO] resolving service instance ipa._acme-server._tcp.ipa.local.
  [INFO]   (<DNS IN SRV rdata: 10 0 443 ipa-ca.ipa.local.>, (b'path=/acme/directory', b'i=dns'))
  [INFO] eligible service instances:
  [INFO]   (<DNS IN SRV rdata: 10 0 443 ipa-ca.ipa.local.>, (b'path=/acme/directory', b'i=dns'))
  [INFO] GET https://ipa-ca.ipa.local/acme/directory
  [WARNING] failed to reach server: <Response [503]>

We can see that the plugin found the service instance and requested
the directory resource, but got a 503 response (as expected).  So,
when service discovery fails the plugin gives you some useful log
output to debug the issue.

The log file is only persisted when service discovery fails,
otherwise it is deleted.  In the current implementation we cannot
write to the "normal" Certbot log file because we don't know where
that is.  The discovery plugin is actually doing all its work
*inside the argument parsing*.  It feels like a brutal hack but it's
the only way I found (in the limited time I had) to override the
``--server`` option whilst keeping the implementation as a plugin,
fully separate from Certbot core.  A nicer implementation is
possible if service discovery were to be implemented in Certbot core
(this would introduce a dependency on *dnspython*).


Next steps
----------

I will present and demo this proposal during the ``acme`` Working
Group meeting at IETF 109 (November 2020).  From there I hope that
it will be adopted, developed, and shepherded through to become an
RFC.  I will also seek feedback from Certbot developers about the
proposal and my experimental implementation.

I also intend to submit another Internet-Draft proposing a mechanism
for servers to advertise their capabilities in the ACME directory
object.  This could be useful to help clients choose from multiple
servers (regardless of how they find out about the servers).  And I
think it's good practice.  When a protocol has many possible
features that a server may or may not implement, servers should
declare their capabilities for the benefit of clients.

Beyond that, I am starting to think about SRVName support in ACME.
This would be useful in enterprise environments and on the open
internet for protocols where SRV records are used to locate servers.
Such protocols include Kerberos, LDAP, SIP and XMPP.
