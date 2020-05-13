---
tags: acme, freeipa, certificates
---

ACME DNS challenges and FreeIPA
===============================

The ACME protocol defined in `RFC 8555`_ defines a `DNS challenge`_
for proving control of a domain name.  In this post I'll explain how
the DNS challenge works and demonstrate how to use the Certbot_ ACME
client with the FreeIPA integrated DNS service.

.. _RFC 8555: https://tools.ietf.org/html/rfc8555
.. _dns challenge: https://tools.ietf.org/html/rfc8555#section-8.4
.. _Certbot: https://certbot.eff.org/


The DNS challenge
-----------------

To prove control of a domain name (the ``dns`` identifier type) ACME
defines the ``dns-01`` challenge type.  It is up to ACME servers
which challenges to create for a given identifier.  If a server
offers multiple challenges (e.g. ``http-01`` and ``dns-01``) the
client can choose which one to attempt.

A DNS challenge object looks like::

   {
     "type": "dns-01",
     "url": "https://example.com/acme/chall/Rg5dV14Gh1Q",
     "status": "pending",
     "token": "evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA"
   }

The ``token`` field is a base64url-encoded high-entropy random
value.  Due to the use of TLS this value should be known only to the
server and client.

The client responds to a ``dns-01`` challenge by provisioning a DNS
**TXT** record containing the SHA-256 digest of the *key
authorisation* value, which is the concatenation of the ``token``
value from the challenge object and the JWK Thumbprint of the
account key.  For example::

   _acme-challenge.www.example.org. 300 IN TXT "gfj9Xq...Rg85nM"

The client then informs the ACME server that it can validate the
challenge::

   POST /acme/chall/Rg5dV14Gh1Q
   Host: example.com
   Content-Type: application/jose+json

   {
     "protected": base64url({
       "alg": "ES256",
       "kid": "https://example.com/acme/acct/evOfKhNU60wg",
       "nonce": "SS2sSl1PtspvFZ08kNtzKd",
       "url": "https://example.com/acme/chall/Rg5dV14Gh1Q"
     }),
     "payload": base64url({}),
     "signature": "Q1bURgJoEslbD1c5...3pYdSMLio57mQNN4"
   }

The ACME server will query the DNS.  When it sees that the expected
TXT record, the challenge (and corresponding identifier
authorisation) are completed.

Because DNSSEC is not widely deployed, ACME servers can mitigate
against DNS-based attacks by querying DNS from mutiple vantage
points.  This increases attack cost and complexity.


DNS and Certbot
---------------

Certbot provides the ``--preferred-challenges={dns,http}`` CLI
option to specify which challenge type to prefer if the server
offers multiple challenges.

There are several `DNS plugins`_ available for using Certbot with
particular DNS services.  For example there are plugins for
Cloudflare, Route53 and many other services.  At a glance, many of
them are packaged for Fedora.  Each DNS plugin has different options
to activate and configure it.  Because we are not using any of these
services I won't go into further details here.

.. _DNS plugins: https://certbot.eff.org/docs/using.html#dns-plugins

Certbot also provides `pre and post validation hooks`_ for the
``--manual`` strategy.  These let the user specify scripts to carry
out challenge provisioning and cleanup steps.  The command line
options are ``--manual-auth-hook`` and ``--manual-cleanup-hook``.

.. _pre and post validation hooks: https://certbot.eff.org/docs/using.html#pre-and-post-validation-hooks


Certbot and FreeIPA DNS
-----------------------

You can use the CLI options described above to implement arbitrary
means of responding to ACME challenges.  And I have done just that
for responding to the ``dns-01`` challenge using the FreeIPA
integrated DNS service.

The FreeIPA integrated DNS is an optional component of FreeIPA.  It
is implmented using the BIND DNS server and a database plugin
causing BIND to read from the FreeIPA replicated LDAP database.  The
DNS service can be installed at server install time, or afterwards
via the ``ipa-dns-install`` command.  The ``freeipa-server-dns``
(Fedora) or ``ipa-server-dns`` (RHEL) package provides this feature.
The rest of this section assumes that the FreeIPA integrated DNS
server is installed and FreeIPA-enrolled client machines are
configured to use it.

The ``ipa dnsrecord-add <zone> <name> ...`` command adds record(s)
to the zone.  The resource types and values are given in options
like ``--aaaa-rec=<ip6addr>`` or ``--txt-rec=<string>``.  The
corresponding command ``dnsrecord-del`` command has the same format.
Knowing that we can also interact with the FreeIPA server via the
``ipalib`` Python library, we have everything we need to implement
the Certbot hook script(s) that will use FreeIPA's DNS to satisfy
the ACME ``dns-01`` challenge.


Hook script
~~~~~~~~~~~

The script is so short I will just include the whole thing here.
I have broken it into chunks with commentary.

.. code:: python

  #!/usr/bin/python3
  import os
  from dns import resolver
  from ipalib import api 
  from ipapython import dnsutil

Shebang, imports.  Trivial.

.. code:: python

  certbot_domain = os.environ['CERTBOT_DOMAIN']
  certbot_validation = os.environ['CERTBOT_VALIDATION']
  if 'CERTBOT_AUTH_OUTPUT' in os.environ:
      command = 'dnsrecord_del'
  else:
      command = 'dnsrecord_add'

Certbot provides the domain name and the *authorisation string* via
environment variables.  In the cleanup phase it also sets the
``CERTBOT_AUTH_OUTPUT`` environment variable.  Therefore I use this
same script for both the authorisation and cleanup phases.  Because
the commands are so similar, the only thing that changes during
cleanup is the command name.

.. code:: python

  validation_domain = f'_acme-challenge.{certbot_domain}'
  fqdn = dnsutil.DNSName(validation_domain).make_absolute()
  zone = dnsutil.DNSName(resolver.zone_for_name(fqdn))
  name = fqdn.relativize(zone)

Construct the validation domain name and find the corresponding DNS
zone, i.e. the zone in which we must create the TXT record.  Then we
relativise the validation domain name against the zone.

.. code:: python

  api.bootstrap(context='cli')
  api.finalize()
  api.Backend.rpcclient.connect()

  api.Command[command](
    zone,
    name,
    txtrecord=[certbot_validation],
    dnsttl=60)

Initialise the API and execute the command.  Note that names of the
keyword arguments are different from the corresponding CLI options.

There are some important **caveats**.  There must be latent,
non-expired Kerberos credentials in the execution environment.
These can be in the default credential cache or specified via the
``KRB5CCNAME`` environment variable (e.g. to point to a keytab
file).  The principal must also have permissions to add and remove
DNS records.


Demo
----

As in previous ACME demos the client machine is enrolled as a
FreeIPA client and trusts the FreeIPA CA.  For this demo Certbot
does not need to run as ``root``.  But by default Certbot tries to
read and write files under ``/etc/letsencrypt``.  I had to override
this behaviour with the following command line options:

``--config-dir DIR``
  Configuration directory. (default: ``/etc/letsencrypt``)
``--work-dir DIR``
  Working directory.  (default: ``/var/lib/letsencrypt``)
``--logs-dir LOGS_DIR``
  Logs directory.  (default: ``/var/log/letsencrypt``)

I defined these options in a shell array variable for use in
subsequent commands.  I included the ACME server configuration too::

  [f31-0:~] ftweedal% CERTBOT_ARGS=( 
  array> --logs-dir ~/certbot/log
  array> --work-dir ~/certbot/work
  array> --config-dir ~/certbot/config
  array> --server https://ipa-ca.ipa.local/acme/directory
  array> )

Next I registered an account::

  [f31-0:~] ftweedal% certbot $CERTBOT_ARGS \
      register --email ftweedal@redhat.com \
      --agree-tos --no-eff-email --quiet
  Saving debug log to /home/ftweedal/certbot/log/letsencrypt.log

  IMPORTANT NOTES:
   - Your account credentials have been saved in your Certbot
     configuration directory at /home/ftweedal/certbot/config. You
     should make a secure backup of this folder now. This configuration
     directory will also contain certificates and private keys obtained
     by Certbot so making regular backups of this folder is ideal.

The ``--no-eff-email`` option suppressed the *"Would you be willing
to share your email address with the Electronic Frontier
Foundation?"* prompt.

The FreeIPA hook script requires Kerberos credentials so I executed
``kinit admin``.  **In production use a less privileged account**
with permissions to add and delete DNS records.

::

  [f31-0:~] ftweedal% kinit admin
  Password for admin@IPA.LOCAL: XXXXXXXX

Now I was ready to request the certificate.  Alongside executing
``certbot``, in another terminal I executed DNS queries to observe
the creation and deletion of the TXT record.

::

  [root@f31-0 ~]# certbot $CERTBOT_ARGS \
      certonly --domain $(hostname) \
      --preferred-challenges dns \
      --manual --manual-public-ip-logging-ok \
      --manual-auth-hook /home/ftweedal/certbot-dns-ipa.py \
      --manual-cleanup-hook /home/ftweedal/certbot-dns-ipa.py
  Saving debug log to /home/ftweedal/certbot/log/letsencrypt.log 
  Plugins selected: Authenticator manual, Installer None                                                            
  Obtaining a new certificate                                                                                       
  Performing the following challenges:
  dns-01 challenge for f31-0.ipa.local
  Running manual-auth-hook command: /home/ftweedal/certbot-dns-ipa.py
  Waiting for verification...
  Cleaning up challenges
  Running manual-cleanup-hook command: /home/ftweedal/certbot-dns-ipa.py

  IMPORTANT NOTES:
   - Congratulations! Your certificate and chain have been saved at:
     /home/ftweedal/certbot/config/live/f31-0.ipa.local/fullchain.pem
     Your key file has been saved at:
     /home/ftweedal/certbot/config/live/f31-0.ipa.local/privkey.pem
     Your cert will expire on 2020-08-11. To obtain a new or tweaked
     version of this certificate in the future, simply run certbot
     again. To non-interactively renew *all* of your certificates, run
     "certbot renew"
   - If you like Certbot, please consider supporting our work by:

     Donating to ISRG / Let's Encrypt:   https://letsencrypt.org/donate
     Donating to EFF:                    https://eff.org/donate-le


The certificate was issued and the process took about 10 seconds.
In the other terminal, running ``dig`` every couple of seconds let
me observe the TXT record that was created and then deleted::

  [f31-0:~] ftweedal% dig +short TXT _acme-challenge.f31-0.ipa.local

  [f31-0:~] ftweedal% dig +short TXT _acme-challenge.f31-0.ipa.local
  "5qkVb3ykx8nRdJOKbKf-xDtoySFl-B2W37bBBOHGoyc"

  [f31-0:~] ftweedal% dig +short TXT _acme-challenge.f31-0.ipa.local
  << no output; record is gone >>


Error handling
--------------

To my surprise, a failure (non-zero exit status) of the
authorisation hook script *does not* cause Certbot to halt.  For
example, after deleting my credential cache with ``kdestroy`` and
running ``certbot`` with the same options as above, Certbot output
an error message and the standard error output from the hook
script::

  ...
  Running manual-auth-hook command: /home/ftweedal/certbot-dns-ipa.py                                               
  manual-auth-hook command "/home/ftweedal/certbot-dns-ipa.py"
  returned error code 1                                
  Error output from manual-auth-hook command certbot-dns-ipa.py:                                                    
  Traceback (most recent call last):                                                                                
    File "/usr/lib/python3.7/site-packages/ipalib/rpc.py", line 647,
    in get_auth_info                               
        response = self._sec_context.step()                                          
    ...

Nevertheless Certbot proceeded to indicating to the server that the
challenge is ready for verification::

  Waiting for verification...                                                                                       
  < 20 seconds elapse >

It then cleaned up the challenges and ran the cleanup hook (which
also failed, as expected, due to no Kerberos credentials)::

  Cleaning up challenges   
  Cleaning up challenges                                                                                            
  Running manual-cleanup-hook command: /home/ftweedal/certbot-dns-ipa.py
  manual-cleanup-hook command "/home/ftweedal/certbot-dns-ipa.py" returned error code 1                             
  Error output from manual-cleanup-hook command certbot-dns-ipa.py:                                                 
  Traceback (most recent call last):   
    ...

Finally it output the error from the ACME service::

  An unexpected error occurred:                                                                                     
  There was a problem with a DNS query during identifier validation ::
    Unable to validate DNS-01 challenge at _acme-challenge.f31-0.ipa.local                                                                                         
  Error: DNS name not found [response code 3]                                                                       
  Please see the logfiles in /home/ftweedal/certbot/log for more details. 

Responding to a challenge after an abnormal exit of the
authorisation hook seems to infringe RFC 8555 §8.2 which states:

    Clients SHOULD NOT respond to challenges until they believe that
    the server's queries will succeed.

I `reported this issue`_ against the Certbot GitHub repository. 

.. _reported this issue:
   https://github.com/certbot/certbot/issues/7990

Discussion
----------

The ``certbot-dns-ipa.py`` script is `available in a Gist`_.  It is
trivial so consider it public domain.

.. _available in a Gist:
   https://gist.github.com/frasertweedale/ca42ff31d5f5b8d3c6d4d3a94f9fbd0e

The script is an artifact of work that is partly an exploration of
ACME use cases, and partly for verifying the PKI and FreeIPA ACME
services.  I encountered no issues on the ACME server side which was
pleasing.

From the client point of view it was good to confirm that what
*sounded* like a valid use case was indeed valid.  Not only that, it
was straightforward thanks to the FreeIPA Python API and the design
of the DNS plugin.  The success of this use case exploration leads
to to a couple of related questions:

- Should we build a "proper" Certbot plugin for FreeIPA DNS?
- Should we distribute and support the manual hook script?

These questions don't need answers today.  But it is good to outline
and compare the options.

From a technical standpoint these are not mutually exclusive; you
could do both.  But from a usage standpoint you only really need one
or the other.  A proper plugin might have better UX and
discoverability but it would be additional work (how much more I'm
not sure yet).  On the other hand the hook script is pretty much
already "done".  We would just need to distribute it, e.g. install
it under ``/usr/libexec/ipa/``.

This post concludes my "trilogy" of ACME client use case demos.  In
the future I will probably explore the intersection of ACME,
OpenShift and FreeIPA.  If so, expect the "sequel trilogy".  But my
immediate focus must be to finish the FreeIPA ACME service and get
it merged upstream.
