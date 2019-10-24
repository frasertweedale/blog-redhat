---
tags: freeipa, howto, certificates
---

Removing the CA from a FreeIPA deployment
=========================================

FreeIPA can be deployed with or without a CA.  By default a CA is
installed; we call this a *CA-ful* deployment.  But if you provide
third party signed certificates for the HTTP, LDAP and (optionally)
Kerberos KDC, then you can create a *CA-less* deployment.

It is possible and supported to promote a CA-less deployment to
CA-ful via the ``ipa-ca-install`` command.  But the opposite is not
true.  There is no supported way to remove the CA from a CA-ful
deployment.  Nevertheless this is sometimes desired, for example to
comply with a corporate security policy.

In this post I will explore how to mutate an existing FreeIPA
deployment from CA-ful to CA-less.


Deployment overview
-------------------

The deployment I used for this exercise has two servers:
``f30-0.ipa.local`` and ``f30-1.ipa.local``.  Both have the CA role
installed.  The CA subject DN is ``CN=Doomed CA,O=IPA.LOCAL``.
There is no KRA installed.  Kerberos PKINIT is disabled.

Both servers are running builds of the FreeIPA ``master`` branch
from October 2019, on Fedora 30.  There should be no substantial
differences in the procedure for official builds in recent versions
of Fedora, RHEL 8 or RHEL 7.

The external CA that will sign the HTTP and LDAP service
certificates is ``CN=Certificate Authority,O=ACME Corporation``.


Success criteria
----------------

Simply uninstalling the Dogtag CA on all CA replicas is not enough.
We want all servers to migrate away from certificate that were
issued by the internal CA.  Specific goals include:

- Replace HTTP, LDAP and (if Kerberos PKINIT enabled) KDC
  certificates with certificates issued by an external CA, on all
  replicas.

- Actually uninstall the Dogtag CA on all CA replicas.

- Cause IPA servers and clients to behave as if the deployment is
  (and always was) CA-less.  In particular, programs like
  ``ipa-server-upgrade`` and ``ipa-certupdate`` must work.

- Replica installation succeeds in the modified deployment
  (third-party service certificates must be supplied, of course).

- Be able to promote the deployment to CA-ful again via the
  ``ipa-ca-install`` command.


Removing the internal CA
------------------------

There are two main approaches one could take.  The first is to
remove the CA role from existing CA replicas.  The second is to
install replicas without the CA role, then remove the CA replicas
from the topology.  In both cases some of the steps (e.g. installing
externally-signed service certificates) will be the same.  This post
describes the first approach (it seems like less work overall).


Add external CA to trust store
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

First add the external root CA certificate to the FreeIPA trust
store::

  [root@f30-0 ~]# ipa-cacert-manage install /root/extca.pem
  Installing CA certificate, please wait
  Verified CN=Certificate Authority,O=ACME Corporation
  CA certificate successfully installed
  The ipa-cacert-manage command was successful

Then run ``ipa-certupdate`` to add the new certificate to system
certificate databases, **on every replica** (not just CA replicas)::

  [root@f30-0 ~]# ipa-certupdate
  Systemwide CA database updated.
  Systemwide CA database updated.
  The ipa-certupdate command was successful



Replacing service certificates
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Next run ``ipa-server-certinstall`` to replace the HTTP and LDAP
service certificates issued by the internal CA with
externally-signed certificates.  Do this **for every server** (only
``f30-0.ipa.local`` is shown below).  ``/root/dmpass`` contains the
``Directory Manager`` password. ``/root/httpd.pin`` and
``/root/ldap.pin`` contain the passwords for the HTTP and LDAP
private keys.

::

  [root@f30-0 ~]# ipa-server-certinstall \
      --dirman-pass $(cat /root/dmpass) \
      --http /root/httpd.pem --pin $(cat /root/httpd.pin)
  Please restart ipa services after installing certificate (ipactl restart)
  The ipa-server-certinstall command was successful

  [root@f30-0 ~]# ipa-server-certinstall \
      --dirman-pass $(cat /root/dmpass) \
      --dirsrv /root/ldap.pem --pin $(cat /root/ldap.pin)
  Please restart ipa services after installing certificate (ipactl restart)
  The ipa-server-certinstall command was successful

  [root@f30-0 ~]# ipactl restart
  Restarting Directory Service
  Restarting krb5kdc Service
  Restarting kadmin Service
  Restarting httpd Service
  Restarting ipa-custodia Service
  Restarting pki-tomcatd Service
  Restarting ipa-otpd Service
  ipa: INFO: The ipactl command was successful

Verify that Apache is presenting the externally-signed service
certificate::

  [root@f30-0 ~]# echo \
     | openssl s_client -connect $(hostname):443 >/dev/null
  depth=1 O = ACME Corporation, CN = Certificate Authority
  verify return:1
  depth=0 O = ACME Corporation, CN = f30-0.ipa.local
  verify return:1
  DONE


Delete CA role configuration
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

FreeIPA uses role entries to track which servers have which features
(CA, KRA, DNS, etc.) enabled.  Search for the entries to delete::

  [root@f30-0 ~]# ldapsearch -Y GSSAPI -QLLL \
      -b cn=masters,cn=ipa,cn=etc,dc=ipa,dc=local \
      '(cn=CA)'
  dn: cn=CA,cn=f30-0.ipa.local,cn=masters,cn=ipa,cn=etc,dc=ipa,dc=local
  ipaConfigString: startOrder 50
  ipaConfigString: caRenewalMaster
  ipaConfigString: enabledService
  cn: CA
  objectClass: nsContainer
  objectClass: ipaConfigObject
  objectClass: top

  dn: cn=CA,cn=f30-1.ipa.local,cn=masters,cn=ipa,cn=etc,dc=ipa,dc=local
  objectClass: nsContainer
  objectClass: ipaConfigObject
  objectClass: top
  cn: CA
  ipaConfigString: startOrder 50
  ipaConfigString: enabledService

Delete these entries::

  [root@f30-0 ~]# ldapdelete -Y GSSAPI -Q \
      cn=CA,cn=f30-0.ipa.local,cn=masters,cn=ipa,cn=etc,dc=ipa,dc=local

  [root@f30-0 ~]# ldapdelete -Y GSSAPI -Q \
      cn=CA,cn=f30-1.ipa.local,cn=masters,cn=ipa,cn=etc,dc=ipa,dc=local

At this point, any command that attempts to communicate with the CA will
fail with a message that the CA is not configured::

  [root@f30-0 ~]# ipa ca-find
  ipa: ERROR: CA is not configured
  [root@f30-0 ~]# ipa cert-show 5
  ipa: ERROR: CA is not configured


Uninstalling Dogtag
^^^^^^^^^^^^^^^^^^^

Issue the ``pkidestroy`` command **on each CA replica** to uninstall
the Dogtag CA::

  [root@f30-0 ~]# pkidestroy -i pki-tomcat -s CA                                                                                 
  Uninstallation log: /var/log/pki/pki-ca-destroy.20191023173820.log                      
  Loading deployment configuration from /var/lib/pki/pki-tomcat/ca/registry/ca/deployment.cfg.
  WARNING: The 'pki_ssl_server_token' in [CA] has been deprecated. Use 'pki_sslserver_token' instead.
  WARNING: The 'pki_pin' in [DEFAULT] has been deprecated. Use 'pki_server_database_password' instead.
  Uninstalling CA from /var/lib/pki/pki-tomcat.                                                                                  
  WARNING: pkihelper      Directory '/etc/pki/pki-tomcat/alias' is either missing or is NOT a directory!
                                                                                                                                 
  Uninstallation complete.        

The warnings can be ignored.


Remove service configuration from state file
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Some processes read from the deployment state file at
``/var/lib/ipa/sysrestore/sysrestore.state`` to decide whether the
CA is installed.  **On every CA replica** delete the following lines
from this file::

  [pki-tomcatd]
  installed = True


Removing (or retaining) trust in the deleted CA
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

If there are no more certificates in use that were issued by the
(now removed) internal CA, we can remove it from the LDAP trust
store::

  % ldapdelete -Y GSSAPI -Q \
      "cn=IPA.LOCAL IPA CA,cn=certificates,cn=ipa,cn=etc,dc=ipa,dc=local"

Otherwise if we still need to trust the old IPA CA, we can rename
it.  This step is necessary because the name ``{REALM} IPA CA``
indicates that this is the internal CA (which it no longer is).

::

  % ldapmodrdn -Y GSSAPI -Q -r \
      "cn=IPA.LOCAL IPA CA,cn=certificates,cn=ipa,cn=etc,dc=ipa,dc=local" \
      "cn=CN\=Doomed CA\,O\=IPA.LOCAL"

We also have to remove the ``{REALM} IPA CA`` certificate from the
FreeIPA 389 DS certificate databases **on every replica**.  Leaving
it as-is will impede future reinstallation of the CA::

  [root@f30-0 ~]# certutil -d /etc/dirsrv/slapd-IPA-LOCAL \
                      -D -n 'IPA.LOCAL IPA CA'

  [root@f30-0 ~]# certutil -d /etc/ipa/nssdb \
                      -D -n 'IPA.LOCAL IPA CA'


Delete IPA CA and sub-CA entries
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Search for all entries with object class ``ipaca`` and delete them::

  [root@f30-0 ~]# ldapsearch -Y GSSAPI -QLLL \
       -b dc=ipa,dc=local '(objectclass=ipaca)' 1.1
  dn: cn=ipa,cn=cas,cn=ca,dc=ipa,dc=local

  [root@f30-0 ~]# ldapdelete -Y GSSAPI -Q \
       cn=ipa,cn=cas,cn=ca,dc=ipa,dc=local

Unless you have created additional (sub-)CAs via the ``ipa ca-add``
command there will be only one entry (``cn=ipa``).


Remove Certmonger tracking requests
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Certmonger tracking requests for the Dogtag system certificates and
IPA RA agent certificate should be removed **on each server**.  The
easiest way to achieve this is with a small Python script::

  [root@f30-0 ~]# python3 <<EOF
  from ipaserver.install.cainstance import CAInstance
  ca = CAInstance()
  ca.stop_tracking_certificates()
  EOF


Testing the outcome
-------------------

We already confirmed that the ``ipa`` subcommands (i.e. commands
that query the IPA API) fail gracefully with a message that the CA
role is not installed.  But there are other commands to check.  In
particular we want to test ``ipa-certupdate``,
``ipa-server-upgrade``, and client and replica installation.

::

  [root@f30-0 ~]# ipa-certupdate
  Systemwide CA database updated.
  Systemwide CA database updated.
  The ipa-certupdate command was successful

::

  [root@f30-0 ~]# ipa-server-upgrade
  Upgrading IPA:. Estimated time: 1 minute 30 seconds
  ...
  The IPA services were upgraded                                      
  The ipa-server-upgrade command was successful                       

So far so good.  I used a third host, ``f30-2.ipa.local``, to test
client and replica installation.  I don't have the required DNS
records so I had to specify the domain and server.

::

  [root@f30-2 ~]# ipa-client-install --server f30-0.ipa.local --domain ipa.local
  This program will set up FreeIPA client.
  Version 4.9.0.dev201910230357+gitc6769ad12

  Autodiscovery of servers for failover cannot work with this configuration.
  If you proceed with the installation, services will be configured to always acce
  ss the discovered server for all operations and will not fail over to other serv
  ers in case of failure.
  Proceed with fixed values and no DNS discovery? [no]: y
  Do you want to configure chrony with NTP server or pool address? [no]: 
  Client hostname: f30-2.ipa.local
  Realm: IPA.LOCAL
  DNS Domain: ipa.local
  IPA Server: f30-0.ipa.local
  BaseDN: dc=ipa,dc=local

  Continue to configure the system with these values? [no]: y
  Synchronizing time
  No SRV records of NTP servers found and no NTP server or pool address was provid
  ed.
  Using default chrony configuration.
  Attempting to sync time with chronyc.
  Time synchronization was successful.
  User authorized to enroll computers: admin
  Password for admin@IPA.LOCAL: 
  Successfully retrieved CA cert
      Subject:     CN=Certificate Authority,O=ACME Corporation
      Issuer:      CN=Certificate Authority,O=ACME Corporation
      Valid From:  2019-10-24 04:01:33
      Valid Until: 2039-10-24 04:01:33

  Enrolled in IPA realm IPA.LOCAL
  Created /etc/ipa/default.conf
  Configured sudoers in /etc/authselect/user-nsswitch.conf
  Configured /etc/sssd/sssd.conf
  Configured /etc/krb5.conf for IPA realm IPA.LOCAL
  Systemwide CA database updated.
  Adding SSH public key from /etc/ssh/ssh_host_ed25519_key.pub
  Adding SSH public key from /etc/ssh/ssh_host_ecdsa_key.pub
  Adding SSH public key from /etc/ssh/ssh_host_rsa_key.pub
  Could not update DNS SSHFP records.
  SSSD enabled
  Configured /etc/openldap/ldap.conf
  Configured /etc/ssh/ssh_config
  Configured /etc/ssh/sshd_config
  Configuring ipa.local as NIS domain.
  Client configuration complete.
  The ipa-client-install command was successful

Client installation succeeded.  We can see that external CA
certificate was retrieved.  I proceeded with replica installation::

  [root@f30-2 ~]# kinit admin                                                     
  Password for admin@IPA.LOCAL: XXXXXXX

  [root@f30-2 ~]# ipa-replica-install \
      --http-cert-file /root/httpd.pem \
      --http-pin $(cat /root/httpd.pin) \
      --dirsrv-cert-file /root/ldap.pem \
      --dirsrv-pin $(cat /root/ldap.pin) \
      --no-pkinit --unattended
  Run connection check to master
  Connection check OK
  Disabled p11-kit-proxy
  Configuring directory server (dirsrv). Estimated time: 30 seconds
    [1/41]: creating directory server instance
    ...
    [10/10]: starting directory server
  Done.
  Finalize replication settings
  Restarting the KDC
  The ipa-replica-install command was successful


Reinstating the internal CA
---------------------------

If you want to once again have a CA-ful FreeIPA deployment, use the
``ipa-ca-install`` command to install the CA.  There is one critical
constraint: **the new CA must not have the same Subject DN as the
previous CA**.  This is to avoid a recurrence of the same
issuer/serial combination, which is a big no-no both for security
and because errors are likely to arise.

So let's install the CA again.  To play it safe I'll use the
newly-installed replica ``f30-2.ipa.local``.  Just in case there is
some "residue" left on the other servers that would prevent
reinstallation of the CA role.

::

  [root@f30-2 ~]# ipa-ca-install \
        --ca-subject "CN=Restored CA,O=IPA.LOCAL"
  Directory Manager (existing master) password:                                   

  The CA will be configured with:                                                 
  Subject DN:   CN=Restored CA,O=IPA.LOCAL                      
  Subject base: O=IPA.LOCAL                                                       
  Chaining:     self-signed                                                       

  Continue to configure the CA with these values? [no]: y                         
  Configuring certificate server (pki-tomcatd). Estimated time: 3 minutes
    [1/29]: configuring certificate server instance               
    [2/29]: Add ipa-pki-wait-running                                              
    [3/29]: reindex attributes                                                    
    [4/29]: exporting Dogtag certificate store pin                
    [5/29]: stopping certificate server instance to update CS.cfg 
    [6/29]: backing up CS.cfg                                                     
    [7/29]: disabling nonces                                                      
    [8/29]: set up CRL publishing
    [9/29]: enable PKIX certificate path discovery and validation
    [10/29]: starting certificate server instance
    [11/29]: configure certmonger for renewals
    [12/29]: requesting RA certificate from CA
    [13/29]: setting audit signing renewal to 2 years
    [14/29]: restarting certificate server 
    [15/29]: publishing the CA certificate 
    [16/29]: adding RA agent as a trusted user
    [17/29]: authorizing RA to modify profiles
    [18/29]: authorizing RA to manage lightweight CAs
    [19/29]: Ensure lightweight CAs container exists
    [20/29]: configure certificate renewals
    [21/29]: Configure HTTP to proxy connections
    [22/29]: restarting certificate server 
    [23/29]: updating IPA configuration
    [24/29]: enabling CA instance
    [25/29]: migrating certificate profiles to LDAP
    [26/29]: importing IPA certificate profiles
    [27/29]: adding default CA ACL
    [28/29]: adding 'ipa' CA entry
    [29/29]: configuring certmonger renewal for lightweight CAs
  Done configuring certificate server (pki-tomcatd).

The installation completed without error.  The deployment is CA-ful
again, but it is a different CA from before.


Issues encountered
------------------

I encountered a significant issue when reinstalling the CA.  If
there are multiple trusted CAs (including the old internal CA) in
``/etc/ipa/ca.crt``, then if the issuer of the 389 DS service
certificate is not the first certificate in that file Dogtag
installation will fail.  This is because the wrong CA certificate is
imported into Dogtag's NSSDB and the issuer of the LDAP certificate
is *not* imported.  As a consequence, Dogtag cannot verify the LDAP
certificate and cannot communicate with the database.  Installation
fails.

This issue is tracked in `upstream ticket 8103`_.

.. _upstream ticket 8103: https://pagure.io/freeipa/issue/8103


I also encountered problems when reinstalling a CA on the servers
from which it had been uninstalled.  A *duplicate entry* error
occurs when setting up the LDAP database::

  [root@f30-1 ~]# ipa-ca-install
  Directory Manager (existing master) password:

  Run connection check to master
  Connection check OK
  Configuring certificate server (pki-tomcatd). Estimated time: 3 minutes
    [1/27]: creating certificate server db
    [error] DuplicateEntry: This entry already exists

  Your system may be partly configured.
  Run /usr/sbin/ipa-server-install --uninstall to clean up.

  Unexpected error - see /var/log/ipareplica-ca-install.log for details:
  DuplicateEntry: This entry already exists

This can probably be averted with additional cleanup steps.  I did
not investigate further because installation of the CA role on a
*new replica* did succeed.  That seems good enough to me.


Conclusion
----------

In this post I explored how to demote a CA-ful FreeIPA deployment to
a CA-less deployment.  The procedure has many steps.  Even in a
CA-less deployment TLS is still required for secure communication
between components.  So one important step is to install
externally-signed service certificates for the web server, directory
server and (if used) the KDC certificates.  But there are several
other steps required to remove the CA from an existing deployment.

The procedure is not officially supported.  If you need to perform
this operation make a snapshot of your deployment so you can roll
back if anything goes wrong, or verify everything in a test
environment first (or both!)

If you need to move from a CA-ful to a CA-less deployment, an
alternative approach would be to create a new, CA-less deployment
and migrate your data across.  Neither approach is very attractive,
to be fair.

As a final observation, the procedure has several steps that are
similar or identical to the steps for `replacing a lost CA`_.

.. _replacing a lost CA: 2018-05-31-replacing-lost-ca.html
