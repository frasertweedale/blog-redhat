---
tags: acme, certificates, freeipa, sysadmin
---

ACME for Apache httpd with mod_md
=================================

`mod_md`_ is an ACME client module for Apache httpd.  In this post I
demonstrate the use mod_md with the FreeIPA ACME service to
automatically acquire certificates for **m**anaged **d**omains from
the FreeIPA CA.

mod_md supports the ``http-01`` and ``tls-alpn-01`` challenges (also
``dns-01`` via external programs).  The FreeIPA ACME service does
not implement ``tls-alpn-01`` so we will use the HTTP-based
challenge.  For this httpd needs to be listening on port 80, which
is the case in the default Fedora configuration::

  [root@f31-0 ~]# grep ^Listen /etc/httpd/conf/httpd.conf
  Listen 80


First step was to install the module::

  [root@f31-0 ~]# dnf install -y mod_md
    <stuff happens>
  Complete!

Looking at the installed configuration files and their contents, I
see the relevant load directives already in place::

  [root@f31-0 ~]# rpm -qc mod_md
  /etc/httpd/conf.modules.d/01-md.conf

  [root@f31-0 ~]# cat /etc/httpd/conf.modules.d/01-md.conf
  LoadModule md_module modules/mod_md.so


I created a minimal ``VirtualHost`` configuration::

  [root@f31-0 ~]# cat >/etc/httpd/conf.d/acme.conf <<EOF
  LogLevel warn md:notice

  MDCertificateAuthority https://ipa-ca.ipa.local/acme/directory
  MDCertificateAgreement accepted

  MDomain f31-0.ipa.local

  <VirtualHost *:443>
      ServerName f31-0.ipa.local

      SSLEngine on
      # no certificates specification
  </VirtualHost>
  EOF

Starting httpd and watching the error log, I observed that shortly
after startup it only took mod_md about 5 seconds to create an
account, submit an order, prove control of the ``f31-0.ipa.local``
DNS name and retrieve the issued certificate::

  [Wed May 06 15:51:37.371414 2020] [core:notice] [pid 82766:tid
    140661368246592] AH00094: Command line: '/usr/sbin/httpd -D
    FOREGROUND'
  [Wed May 06 15:51:43.086719 2020] [md:notice] [pid 82778:tid
    140661321930496] AH10059: The Managed Domain f31-0.ipa.local has
    been setup and changes will be activated on next (graceful) server
    restart.

The notice that we still need to perform a (graceful) restart is
important.  Indeed a requests from another host still fails with a
self-signed certificate warning::

  [f31-1:~] ftweedal% curl https://f31-0.ipa.local/
  curl: (60) SSL certificate problem: self signed certificate
  More details here: https://curl.haxx.se/docs/sslcerts.html

  curl failed to verify the legitimacy of the server and therefore
  could not establish a secure connection to it. To learn more about
  this situation and how to fix it, please visit the web page
  mentioned above.

After preforming a (graceful) restart of httpd::

  [f31-0:~] ftweedal% sudo systemctl reload httpd

Requests now work (never mind the 403 response status)::

  [f31-1:~] ftweedal% curl --head https://f31-0.ipa.local/
  HTTP/1.1 403 Forbidden
  Date: Wed, 06 May 2020 06:11:43 GMT
  Server: Apache/2.4.43 (Fedora) OpenSSL/1.1.1d mod_auth_gssapi/1.6.1 mod_wsgi/4.6.6 Python/3.7
  Last-Modified: Thu, 25 Jul 2019 05:18:03 GMT
  ETag: "15bc-58e7a8ccdb8c0"
  Accept-Ranges: bytes
  Content-Length: 5564
  Content-Type: text/html; charset=UTF-8

``curl -v`` output included the following certificate detail::

  * Server certificate:
  *  subject: CN=f31-0.ipa.local
  *  start date: May  6 05:51:41 2020 GMT
  *  expire date: Aug  4 05:51:41 2020 GMT
  *  subjectAltName: host "f31-0.ipa.local" matched cert's "f31-0.ipa.local"
  *  issuer: O=IPA.LOCAL 202004011654; CN=Certificate Authority
  *  SSL certificate verify ok.

Observe that it is a short-lived certificate issued by the FreeIPA
CA.

The fact that a graceful restart was required suggests that if you
are using mod_md in production, you should configure a cron job (or
equivalent) to execute that on a regular schedule.  The
``MDRenewWindow`` directive defines the remaining certificate
lifetime at which mod_md will first attempt to renew the
certificate.  The default value is ``33%`` which for 90 day
certificates is 30 days.  Therefore with 90 days certificates and
the default ``MDRenewWindow 33%``, restarting weekly seems
reasonable.

One last curiousity: by default mod_md publishes a "certificate
status" resource at ``.httpd/certificate-status`` for each managed
domain::

  [f31-1:~] ftweedal% curl \
      https://f31-0.ipa.local/.httpd/certificate-status
  {
    "valid": {
      "until": "Tue, 04 Aug 2020 05:51:41 GMT",
      "from": "Wed, 06 May 2020 05:51:41 GMT"
    },
    "serial": "1E",
    "sha256-fingerprint": "a70d2182f347cf9dddfbd19a14243c5efe24df55fa5728297c667494a28e7d2e"
  }

This can be suppressed by ``MDCertificateStatus off`` which is a
server-wide setting.


Discussion
----------

Confession time.  The above scenario did not go anywhere near as
smoothly as portrayed above.  In fact, mod_md was failing
immediately after retrieving the directory resource::

  [Tue May 05 22:28:32.462108 2020] [md:warn] [pid 68047:tid
  140418815502080] (22)Invalid argument: md[f31-0.ipa.local]
  while[Contacting ACME server for f31-0.ipa.local at
  https://ipa-ca.ipa.local/acme/directory] detail[Unable to understand
  ACME server response from <https://ipa-ca.ipa.local/acme/directory>.
  Wrong ACME protocol version or link?]

I went to the mod_md source code to investigate.  The problem was
that mod_md required the ACME ``revokeCert`` and ``keyChange``
(account key rollover) resources to be defined in the resource
document, even though mod_md does not use those capabilities (at
this time).  The Dogtag ACME responder has not yet implemented key
rollover.  As a consequence, mod_md refused to interact with it.

What does RFC 8555 have to say about this?  §7.1 states:

    The server MUST provide "directory" and "newNonce" resources.

But there is no explicit statement about whether other resources
are, or are not, required (with the exception of the ``newAuthz``
resource other resource which is optional).  My conclusion is that
mod_md, in checking for resources it doesn't even use, is too
strict.  I submitted `a pull request`_ to
https://github.com/icing/mod_md to relax the check.  It was accepted
and merged the next day.

.. _a pull request: https://github.com/icing/mod_md/pull/214

Note that mod_md has also been pulled into the httpd codebase,
although it does not seem to be as actively maintained there at this
point in time.  I suppose that the httpd code is periodically
updated with the code from the *icing* respository.  Nevertheless I
also submitted a `pull request to httpd`_.  At time of publication
of this post there has been no activity.  I have also submitted bugs
against the Fedora and RHEL mod_md packages.

.. _pull request to httpd: https://github.com/apache/httpd/pull/122

In the meantime I built a version of the Fedora package containing
my patch.  This time mod_md was able to successfully validate the
identifier and finalise the order, causing the certificate to be
issued.  But it was not able to retrieve the certificate; mod_md
does not handle the absense of the ``Location`` header in the
response to the finalise request.  This header was required in an
earlier (pre-RFC) draft of the ACME protocol, but it is not required
any more.  *Boulder* (the ACME server implementation used by Let's
Encrypt) does set it so mod_md works fine with Boulder.  But the
Dogtag ACME service did not set it and mod_md fails at this point,
putting the client-side order data into an unrecoverable state.

The quick fix was to update the Dogtag ACME service to include the
Location header.  I also `reported the issue`_ in the upstream
repository.

.. _reported the issue: https://github.com/icing/mod_md/issues/216

That's it for this demo.  For my next FreeIPA ACME demo I'm going to
attempt DNS-based identifier validation challenges with Certbot and
FreeIPA's integrated DNS.
