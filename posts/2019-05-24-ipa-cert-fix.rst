---
tags: freeipa, troubleshooting, renewal, certificates
---

Fixing expired system certificates in FreeIPA
=============================================

In previous posts I outlined and demonstrated the ``pki-server
cert-fix`` tool.  This tool is part of Dogtag PKI.  I also discussed
what additional functionality would be needed to successfully use
this tool in a FreeIPA environment.

This post details the result of the effort to make ``cert-fix``
useful for FreeIPA administrators.  We implemented a wrapper
program, ``ipa-cert-fix``, which performs FreeIPA-specific steps in
addition to executing ``pki-server cert-fix``.


What does ``ipa-cert-fix`` do?
------------------------------

In brief, the steps performed by ``ipa-cert-fix`` are:

1. Inspect deployment to work out which certificates need renewing.
   This includes both Dogtag system certificates, FreeIPA-specific
   certificates (HTTP, LDAP, KDC and IPA RA).

#. Print intentions and await operator confirmation.

#. Invoke ``pki-server cert-fix`` to renew expired certificates,
   including FreeIPA-specific certificates.

#. Install renewed FreeIPA-specific certificates to their respective
   locations.

#. If any shared certificates were renewed (Dogtag system
   certificates excluding HTTP, and IPA RA), import them to the LDAP
   ``ca_renewal`` subtree and set the ``caRenewalMaster``
   configuration to be the current server.  This allows CA replicas
   to pick up the renewed shared certificates.

#. Restart FreeIPA (``ipactl restart``).


Demonstration
-------------

For this demonstration I used a deployment with the following
characteristics:

- Two servers, ``f29-0`` and ``f29-1``, with CA on both.

- ``f29-0`` is the current *CA renewal master*.

- A KRA instance is installed on ``f29-1``.

- The deployment was created on 2019-05-24, so most of the
  certificates expire on or before 2021-05-24 (the exception being
  the CA certificate).

On both machines I disabled ``chronyd`` and put the clock forward 27
months, so that all the certificates (except the IPA CA itself) are
expired::

  [f29-1] ftweedal% sudo systemctl stop chronyd
  [f29-1] ftweedal% date
  Fri May 24 12:01:16 AEST 2019
  [f29-1] ftweedal% sudo date 082412012021
  Tue Aug 24 12:01:00 AEST 2021

After ``ipactl restart`` the Dogtag CA did not start, and we cannot
communicate with FreeIPA due to the expired HTTP certificate::

  [f29-1] ftweedal% sudo ipactl status
  Directory Service: RUNNING
  krb5kdc Service: RUNNING
  kadmin Service: RUNNING
  httpd Service: RUNNING
  ipa-custodia Service: RUNNING
  pki-tomcatd Service: STOPPED
  ipa-otpd Service: RUNNING
  ipa: INFO: The ipactl command was successful

  [f29-1] ftweedal% ipa user-find
  ipa: ERROR: cannot connect to 'https://f29-1.ipa.local/ipa/json':
    [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
    certificate has expired (_ssl.c:1056)


Fixing the first server
^^^^^^^^^^^^^^^^^^^^^^^

I will repair ``f29-1`` first, so that we can see why resetting the
CA renewal master is an important step performed by
``ipa-cert-fix``.

I ran ``ipa-cert-fix`` as ``root``.  It analyses the server, then
prints a warning and the list of certificates to be renewed, and
asks for confirmation::

  [f29-1] ftweedal% sudo ipa-cert-fix

                            WARNING

  ipa-cert-fix is intended for recovery when expired certificates
  prevent the normal operation of FreeIPA.  It should ONLY be used
  in such scenarios, and backup of the system, especially certificates
  and keys, is STRONGLY RECOMMENDED.


  The following certificates will be renewed:

  Dogtag sslserver certificate:                                                                                                                                                                                [2/34]
    Subject: CN=f29-1.ipa.local,O=IPA.LOCAL 201905222205                                                                                                                                                             
    Serial:  13
    Expires: 2021-05-12 05:55:47

  Dogtag subsystem certificate:
    Subject: CN=CA Subsystem,O=IPA.LOCAL 201905222205
    Serial:  4
    Expires: 2021-05-11 12:07:11

  Dogtag ca_ocsp_signing certificate:
    Subject: CN=OCSP Subsystem,O=IPA.LOCAL 201905222205
    Serial:  2
    Expires: 2021-05-11 12:07:11

  Dogtag ca_audit_signing certificate:
    Subject: CN=CA Audit,O=IPA.LOCAL 201905222205
    Serial:  5
    Expires: 2021-05-11 12:07:12

  Dogtag kra_transport certificate:
    Subject: CN=KRA Transport Certificate,O=IPA.LOCAL 201905222205
    Serial:  268369921
    Expires: 2021-05-12 06:00:10

  Dogtag kra_storage certificate:
    Subject: CN=KRA Storage Certificate,O=IPA.LOCAL 201905222205
    Serial:  268369922
    Expires: 2021-05-12 06:00:10

  Dogtag kra_audit_signing certificate:
    Subject: CN=KRA Audit,O=IPA.LOCAL 201905222205
    Serial:  268369923
    Expires: 2021-05-12 06:00:11

  IPA IPA RA certificate:
    Subject: CN=IPA RA,O=IPA.LOCAL 201905222205
    Serial:  7
    Expires: 2021-05-11 12:07:47

  IPA Apache HTTPS certificate:
    Subject: CN=f29-1.ipa.local,O=IPA.LOCAL 201905222205
    Serial:  12
    Expires: 2021-05-23 05:54:11

  IPA LDAP certificate:
    Subject: CN=f29-1.ipa.local,O=IPA.LOCAL 201905222205
    Serial:  11
    Expires: 2021-05-23 05:53:58

  IPA KDC certificate:
    Subject: CN=f29-1.ipa.local,O=IPA.LOCAL 201905222205
    Serial:  14
    Expires: 2021-05-23 05:57:50

  Enter "yes" to proceed:

Observe that the KRA certificates are included (we are on
``f29-1``).  I type "yes" and continue.  After a few minutes the
process has completed::

  Proceeding.
  Renewed Dogtag sslserver certificate:
    Subject: CN=f29-1.ipa.local,O=IPA.LOCAL 201905222205
    Serial:  268369925
    Expires: 2023-08-14 02:19:33

  ... (9 certificates elided)

  Renewed IPA KDC certificate:
    Subject: CN=f29-1.ipa.local,O=IPA.LOCAL 201905222205
    Serial:  268369935
    Expires: 2023-08-25 02:19:42

  Becoming renewal master.
  The ipa-cert-fix command was successful

As suggested by the expiry dates, it took about 11 seconds to renew
all 11 certifiates.  So why did it take so long?  The ``pki-server
cert-fix`` command, which is part of Dogtag and invoked by
``ipa-cert-fix``, restarts the Dogtag instance as its final step.
Although a new LDAP certificate was issued, it is not yet been
installed in 389's certificate database.  Dogtag fails to start; it
cannot talk to LDAP because of the expired certificate, and the
restart operation hangs for a while.  ``ipa-cert-fix`` knows to
expect this and ignores the ``pki-server cert-fix`` failure when the
LDAP certificate needs renewal.

``ipa-cert-fix`` also reported that it was setting the renewal
master (because shared certificates were renewed).  Let's check the
server status and verify the configuration.

::

  [f29-1] ftweedal% sudo ipactl status
  Directory Service: RUNNING
  krb5kdc Service: RUNNING
  kadmin Service: RUNNING
  httpd Service: RUNNING
  ipa-custodia Service: RUNNING
  pki-tomcatd Service: RUNNING
  ipa-otpd Service: RUNNING
  ipa: INFO: The ipactl command was successful

The server is up and running.

::

  [f29-1] ftweedal% kinit admin
  Password for admin@IPA.LOCAL:
  Password expired.  You must change it now.
  Enter new password:
  Enter it again:

Passwords have expired (due to time-travel).

::

  [f29-1] ftweedal% ipa config-show |grep renewal
    IPA CA renewal master: f29-1.ipa.local

``f29-1`` has indeed become the renewal master.  Oh, and the HTTP
and LDAP certifiate have been fixed.

::

  [f29-1] ftweedal% ipa cert-show 1 | grep Subject
    Subject: CN=Certificate Authority,O=IPA.LOCAL 201905222205

And the IPA framework can talk to Dogtag.  This proves that the IPA
RA and Dogtag HTTPS and subsystem certificates are valid.

Fixing subsequent servers
^^^^^^^^^^^^^^^^^^^^^^^^^

Jumping back onto ``f29-0``, let's look at the Certmonger request
statuses::

  [f29-0] ftweedal% sudo getcert list \
                    | egrep '^Request|status:|subject:'
  Request ID '20190522120745':
          status: CA_UNREACHABLE
          subject: CN=IPA RA,O=IPA.LOCAL 201905222205
  Request ID '20190522120831':
          status: CA_UNREACHABLE
          subject: CN=CA Audit,O=IPA.LOCAL 201905222205
  Request ID '20190522120832':
          status: CA_UNREACHABLE
          subject: CN=OCSP Subsystem,O=IPA.LOCAL 201905222205
  Request ID '20190522120833':
          status: CA_UNREACHABLE
          subject: CN=CA Subsystem,O=IPA.LOCAL 201905222205
  Request ID '20190522120834':
          status: MONITORING
          subject: CN=Certificate Authority,O=IPA.LOCAL 201905222205
  Request ID '20190522120835':
          status: CA_UNREACHABLE
          subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201905222205
  Request ID '20190522120903':
          status: CA_UNREACHABLE
          subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201905222205
  Request ID '20190522120932':
          status: CA_UNREACHABLE
          subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201905222205
  Request ID '20190522120940':
          status: CA_UNREACHABLE
          subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201905222205

The ``MONITORING`` request is the CA certificate.  All the other
requests are stuck in ``CA_UNREACHABLE``.

The Certmonger tracking requests need to communicate with LDAP to
retrieve shared certificates.  So we have to ``ipactl restart`` with
``--force`` to ignore individual service startup failures (Dogtag
will fail)::

  [f29-0] ftweedal% sudo ipactl restart --force
  Skipping version check
  Starting Directory Service
  Starting krb5kdc Service
  Starting kadmin Service
  Starting httpd Service
  Starting ipa-custodia Service
  Starting pki-tomcatd Service
  Starting ipa-otpd Service
  ipa: INFO: The ipactl command was successful

  [f29-0] ftweedal% sudo ipactl status
  Directory Service: RUNNING
  krb5kdc Service: RUNNING
  kadmin Service: RUNNING
  httpd Service: RUNNING
  ipa-custodia Service: RUNNING
  pki-tomcatd Service: STOPPED
  ipa-otpd Service: RUNNING
  ipa: INFO: The ipactl command was successful

Now Certmonger is able to renew the shared certificates by
retrieving the new certificate from LDAP.  The IPA-managed
certificates are also able to be renewed by falling back to
requesting them from another CA server (the already repaired
``f29-1``).  After a short wait, ``getcert list`` shows that all but
one of the certificates have been renewed::

  [f29-0] ftweedal% sudo getcert list \
                    | egrep '^Request|status:|subject:'
  Request ID '20190522120745':
          status: MONITORING
          subject: CN=IPA RA,O=IPA.LOCAL 201905222205
  Request ID '20190522120831':
          status: MONITORING
          subject: CN=CA Audit,O=IPA.LOCAL 201905222205
  Request ID '20190522120832':
          status: MONITORING
          subject: CN=OCSP Subsystem,O=IPA.LOCAL 201905222205
  Request ID '20190522120833':
          status: MONITORING
          subject: CN=CA Subsystem,O=IPA.LOCAL 201905222205
  Request ID '20190522120834':
          status: MONITORING
          subject: CN=Certificate Authority,O=IPA.LOCAL 201905222205
  Request ID '20190522120835':
          status: CA_UNREACHABLE
          subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201905222205
  Request ID '20190522120903':
          status: MONITORING
          subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201905222205
  Request ID '20190522120932':
          status: MONITORING
          subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201905222205
  Request ID '20190522120940':
          status: MONITORING
          subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201905222205

The final ``CA_UNREACHABLE`` request is the Dogtag HTTP certificate.
We can now run ``ipa-cert-fix`` on ``f29-0`` to repair this
certificate::

  [f29-0] ftweedal% sudo ipa-cert-fix

                            WARNING

  ipa-cert-fix is intended for recovery when expired certificates
  prevent the normal operation of FreeIPA.  It should ONLY be used
  in such scenarios, and backup of the system, especially certificates
  and keys, is STRONGLY RECOMMENDED.


  The following certificates will be renewed:

  Dogtag sslserver certificate:
    Subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201905222205
    Serial:  3
    Expires: 2021-05-11 12:07:11

  Enter "yes" to proceed: yes
  Proceeding.
  Renewed Dogtag sslserver certificate:
    Subject: CN=f29-0.ipa.local,O=IPA.LOCAL 201905222205
    Serial:  15
    Expires: 2023-08-14 04:25:05

  The ipa-cert-fix command was successful


All done?
^^^^^^^^^

Yep.  A subsequent execution of ``ipa-cert-fix`` shows that there is
nothing to do, and exits::

  [f29-0] ftweedal% sudo ipa-cert-fix
  Nothing to do.
  The ipa-cert-fix command was successful


Feature status
--------------

Against the usual procedure for FreeIPA (and Red Hat projects in
general), ``ipa-cert-fix`` was developed "downstream-first".  It has
been merged to the ``ipa-4-6`` branch, but there might not even be
another upstream release from that branch.  But there might be a
future RHEL release based on that branch (the savvy reader might
infer a high degree of certainty, given we actually bothered to do
that…)

In the meantime, work to forward-port the feature to ``master`` and
newer branches is ongoing.  I hope that it will be merged in the
next week or so.
