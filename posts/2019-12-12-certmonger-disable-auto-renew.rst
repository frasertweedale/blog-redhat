---
tags: certificates, renewal, certmonger
---

Disabling Certmonger auto-renewal
=================================

A customer recently asked how to disable Certmonger auto-renewal of
some FreeIPA system certificates.  Their organisation's security
policy prohibited auto-renewal.  (This is not a good idea in
general, but this was a very security-conscious organisation so I'll
assume they have good reasons).

One way to achieve this is to remove the Certmonger tracking
requests via ``getcert stop-tracking``.  But when it comes time to
renew the certificate, this makes life hard.  The Certmonger
tracking requests are set up to:

- Use the correct renewal helpers to issue the certificate properly

- Store the certificate in the correct place

- Copy the certificate to particular LDAP entries to ensure the
  FreeIPA system continues to function

Removing the tracking request means that you have to do all the
above tasks yourself.  And the steps differ depending on the
certificate being renewed.  There are many ways to mess up.

A better approach is to keep the Certmonger tracking requests
defined, but disable auto-renewal.  It is not obvious that you can
even do this, let alone *how* to do it.  And that is why I wrote
this post.  The command is::

  # getcert start-tracking -i $REQUEST_ID --no-renew

Don't let the name ``start-tracking`` trick you.  If you supply ``-i
$REQUEST_ID`` this command will modify the existing request.  With
auto-renewal disabled, to renew the certificate you must manually
trigger it via::

  # getcert resubmit -i $REQUEST_ID

If you want to reenable auto-renewal, use the ``--renew`` flag::

  # getcert start-tracking -i $REQUEST_ID --renew

The following transcript deals with the IPA RA agent certificate tracking
request.  We first disable auto-renewal, then manually renew the
certificate, and finally reenable auto-renewal.

::

  # getcert list -i 20191206060652                                                                                                                        [6/38]
  Number of certificates and requests being tracked: 9.           
  Request ID '20191206060652':                                                          
          status: MONITORING                                                            
          stuck: no                                                                     
          key pair storage: type=FILE,location='/var/lib/ipa/ra-agent.key'
          certificate: type=FILE,location='/var/lib/ipa/ra-agent.pem'
          CA: dogtag-ipa-ca-renew-agent
          issuer: CN=Certificate Authority,O=IPA ACME 201912061604
          subject: CN=IPA RA,O=IPA ACME 201912061604                                                                                                                           
          expires: 2021-11-25 17:06:54 AEDT
          key usage: digitalSignature,keyEncipherment,dataEncipherment
          eku: id-kp-clientAuth
          pre-save command: /usr/libexec/ipa/certmonger/renew_ra_cert_pre
          post-save command: /usr/libexec/ipa/certmonger/renew_ra_cert
          track: yes
          auto-renew: yes

  # getcert start-tracking -i 20191206060652 --no-renew
  Request "20191206060652" modified.

  # getcert list -i 20191206060652 |grep auto-renew                       
          auto-renew: no

  # openssl x509 -serial < /var/lib/ipa/ra-agent.pem
  serial=07

  # getcert resubmit -i 20191206060652
  Resubmitting "20191206060652" to "dogtag-ipa-ca-renew-agent".

  # getcert list -i 20191206060652 |grep status
          status: MONITORING

  # openssl x509 -serial -noout < /var/lib/ipa/ra-agent.pem
  serial=0B

  # getcert start-tracking -i 20191206060652 --renew
  Request "20191206060652" modified.

  # getcert list -i 20191206060652 |grep auto-renew
          auto-renew: yes

A final note.  I used the long form ``--[no-]renew`` options.  I
prefer long options because they are usually easier for readers
(including *future me*) to understand.  But
``getcert-start-tracking(1)`` and other Certmonger man pages don't
even mention the long options.  The corresponding short options are
``-r`` (enable auto-renew) and ``-R`` (disable auto-renew).
