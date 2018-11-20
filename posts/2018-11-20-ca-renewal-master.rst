FreeIPA CA renewal master explained
===================================

Every FreeIPA deployment has a critical setting called the *CA
renewal master*.  In this post I explain how this setting is used,
why it is important, and the consequences of improper configuration.
I'll also discuss scenarios which cause the value to change, and why
and how you would change it manually.

What is the CA renewal master?
------------------------------

The CA renewal master configuration controls which CA replica is
responsible for renewing some important certificate used within a
FreeIPA deployment.  I will call these *system certificates*.

Unlike service certificates (e.g. for HTTP and LDAP) which have
different keypairs and subject names on different servers, FreeIPA
system certificates, and their keys, are shared by all CA replicas.
These include the IPA CA certificate, OCSP certificate, Dogtag
subsystem certificates, Dogtag audit signing certificate, IPA RA
agent certificate and KRA transport and storage certificates.

The current CA renewal master configuration can be viewed via
``ipa config-show``::

  [f28-1] ftweedal% ipa config-show | grep 'CA renewal master'
    IPA CA renewal master: f28-1.ipa.local

Under the hood, this configuration is a *server role attribute*.
The CA renewal master is indicated by the presence of an
``(ipaConfigString=caRenewalMaster)`` attribute value on an IPA
server's CA role object.  You can determine the renewal master via a
plain LDAP search::

  [f28-1] ftweedal% ldapsearch -LLL \
        -D "cn=Directory Manager" \
        "(ipaConfigString=carenewalmaster)"
  dn: cn=CA,cn=f28-1.ipa.local,cn=masters,cn=ipa,cn=etc,dc=ipa,dc=local
  objectClass: nsContainer
  objectClass: ipaConfigObject
  objectClass: top
  cn: CA
  ipaConfigString: startOrder 50
  ipaConfigString: caRenewalMaster
  ipaConfigString: enabledService

The configuration is automatically set to the first master in the
topology on which the CA role was installed.  Unless you installed
without a CA, this is the original master set up via
``ipa-server-install``.


What problem is solved by having a CA renewal master?
-----------------------------------------------------

All CA replicas have tracking requests for all system
certificates.  But if all CA replicas renewed system certificates
independently, they would end up with different certificates.
This is especially a problem for the CA certificate, and the
subsystem and IPA RA certificates which get stored in LDAP for
authentication purposes.  The certificates must match exactly,
otherwise there will be authentication failures between the
FreeIPA framework and Dogtag, and between Dogtag and LDAP.

Appointing one CA replica as the renewal master allows the system
certificates to be renewed exactly once, when required.


How do other replicas acquire the updated certificates?
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The Certmonger tracking requests on all CA replicas use the
``dogtag-ipa-ca-renew-agent`` renewal helper.  This program reads
the CA renewal master configuration.  If the current host is the
renewal master, it performs the renewal, and stores the certificate
in LDAP under
``cn=<nickname>,cn=ca_renewal,cn=ipa,cn=etc,{basedn}``.
Additionally, if the certificate is the IPA RA or the Dogtag CA
subsystem certificate, the new certificate gets added to the
``userCertificate`` attribute of the corresponding LDAP user entry

If the renewal master is a different host, the latest certificate is
retrieved from the ``ca_renewal`` LDAP entry and returned to
Certmonger.  Due to non-determinism in exactly when Certmonger
renewal attempts will occur, the non-renewal helper could attempt to
"renew" the certificate before the renewal master has actually
renewed the certificate.  So it is *not an error* for the renewal
helper to return the old (soon to expire) certificate.  Certmonger
will keep attempting to renew the certificate (with some delay
between attempts) until it can retrieve the updated certificate
(which will not expire soon).


What can go wrong?
------------------

If it wasn't clear already, a (CA-ful) FreeIPA deployment must at
all times have exactly one CA replica configured as the renewal
master.  That server must be online, operating normally, and
replicating properly with other servers.  Let's look at what happens
if these conditions are not met.

If the CA renewal master configuration refers to a server that has
been decommissioned, or is offline, then no server will actually
renew the certificates.  All the non-renewal master servers will
happily reinstall the current certificate, until they expire, and
things will break.  The troublesome thing about certificates is even
one expired certificate can cause renewal failures for other
certificates.  The problems cascade and eventually the whole
deployment is busted.

FreeIPA has a simple protection in place to ensure the renewal
master configuration stays valid.  Servers can be deleted from the
topology via the ``ipa server-del``, ``ipa-replica-manage del``,
``ipa-csreplica-manage del`` or ``ipa-server-install --uninstall``
command.  In these commands, if the server being deleted is the
current CA renewal master, a different CA replica is elected as the
new CA renewal master.

These protections only go so far.  If the renewal master is still
part of the topology but is offline for an extended duration it may
miss a renewal window, causing expired certificates.  If there are
replication problems between the renewal master and other CA
replicas, renewal might succeed, but the other CA replicas might not
be able to retrieve the updated certificates before they expire.
All of these problems (and more) have been seen in the wild.

I have seen cases where a CA renewal master was simply
decommissioned without formally removing it from the FreeIPA
topology.  I have also seen cases where there was no CA renewal
master configured (I do not know how this situation arose).  Both of
these scenarios have similar consequences to the "offline for
extended duration" scenario.

What would happen if you had two (or more) CA replicas with
``(ipaConfigString=caRenewalMaster)``?  I haven't seen this one in
the wild, but I would not be surprised if one day I did see it.  In
this case, multiple CA replicas will perform renewals.  Will clobber
each others' certificates, and will result in some replicas having
RA Agent or Dogtag subsystem certificates out of sync with the
corresponding user entries in LDAP.  This is a less catastrophic
consequence than the aforementioned scenarios, but still serious.
It will result in Dogtag or IPA RA authentication failures on some
(or most) CA replicas.


Why and how to change the CA renewal master
-------------------------------------------

Why would you need to change the renewal master configuration?
Assuming the existing configuration is valid, the main reason you
would need to change it is in anticipation of the decommissioning of
the existing CA renewal master.  You may wish to appoint a
particular server as the new renewal master.  As discussed above,
the commands that remove servers from the topology will do this
automatically, but *which server* will be chosen is out of your
hands.  So you can get one step ahead and change the renewal master
yourself.

In my test setup there are two CA replicas::

  [f28-1] ftweedal% ipa server-role-find --role 'CA server'
  ----------------------
  2 server roles matched
  ----------------------
    Server name: f28-0.ipa.local
    Role name: CA server
    Role status: enabled

    Server name: f28-1.ipa.local
    Role name: CA server
    Role status: enabled
  ----------------------------
  Number of entries returned 2
  ----------------------------

The current renewal master is ``f28-1.ipa.local``::

  [f28-1] ftweedal% ipa config-show | grep 'CA renewal master'
    IPA CA renewal master: f28-1.ipa.local

The preferred way to change the renewal master configuration is via
the ``ipa config-mod`` command::

  [f28-1] ftweedal% ipa config-mod \
        --ca-renewal-master-server f28-0.ipa.local \
        | grep 'CA renewal master'
    IPA CA renewal master: f28-0.ipa.local

You can also use the ``ipa-csreplica-manage`` command.  This
requires the ``Directory Manager`` passphrase::

  [f28-1] ftweedal% ipa-csreplica-manage \
                      set-renewal-master f28-1.ipa.local
  Directory Manager password: XXXXXXXX

  f28-1.ipa.local is now the renewal master


If for whatever reason the current renewal master configuration is
invalid, you can use these same commands to reset it.  As a last
resort, you can modify the LDAP objects directly to ensure that
exactly one CA role object has
``(ipaConfigString=caRenewalMaster)``.  Note that both the attribute
name (``ipaConfigString``) and value (``caRenewalMaster``) are
case-*insensitive*.

Finally, let's observe what happens when we remove a server from the
topology.  I'll remove ``f28-1.ipa.local`` (the current renewal
master) using the ``ipa-server-install --uninstall`` command.  After
this operation, the CA renewal master configuration should point to
``f28-0.ipa.local`` (the only other CA replica in the topology).

::

  [f28-1:~] ftweedal% sudo ipa-server-install --uninstall

  This is a NON REVERSIBLE operation and will delete all data
  and configuration!
  It is highly recommended to take a backup of existing data
  and configuration using ipa-backup utility before proceeding.

  Are you sure you want to continue with the uninstall procedure? [no]: yes
  Forcing removal of f28-1.ipa.local
  Failed to cleanup f28-1.ipa.local DNS entries: DNS is not configured
  You may need to manually remove them from the tree
  ------------------------------------
  Deleted IPA server "f28-1.ipa.local"
  ------------------------------------
  Shutting down all IPA services
  Unconfiguring CA
  ... (snip!)
  Client uninstall complete.
  The ipa-client-install command was successful
  The ipa-server-install command was successful

Jumping across to ``f28-0.ipa.local``, I confirm that
``f28-0.ipa.local`` has become the renewal master::

  [f28-0] ftweedal% ipa config-show |grep 'CA renewal master'
    IPA CA renewal master: f28-0.ipa.local


Explicit CA certificate renewal
-------------------------------

There is one more scenario that can cause the CA renewal master to
be changed.  When the IPA CA certificate is explicitly renewed via
the ``ipa-cacert-manage renew`` command the server on which the
operation is performed becomes the CA renewal master.  This is to
cause the CA replica that *was* the renewal master to retrieve the
new CA certificate from LDAP instead of renewing it.


Conclusion
----------

In this post I explained what the CA renewal master configuration is
for and what it looks like under the hood.  For FreeIPA/Dogtag
system certificates, the CA renewal master configuration controls
which CA replica actually performs renewal.  The CA renewal master
stores the renewed certificates in LDAP, and all other CA replicas
look for them there.  The ``dogtag-ipa-ca-renew-agent`` Certmonger
renewal helper implements both of these behaviours, using the CA
renewal master configuration to decide which behaviour to execute.

There must be exactly one CA renewal master in a topology and it
must be operational.  I discussed the consequences of various
configuration or operational problems.  I also explained why you
might want to change the CA renewal master, and how to do it.

The CA renewal master is a critical configuration and incorrect
renewal master configuration is often a factor in complex customer
cases involving FreeIPA's PKI.  Commands that remove servers from
the topology *should* elect a new CA renewal master when necessary.
But misconfigurations do arise (if only we could know all the ways
how!)

The upcoming FreeIPA `Healthcheck
<https://www.freeipa.org/page/V4/Healthcheck>`_ feature will, among
other checks, confirm that the CA renewal master configuration is
sane.  It will not (in the beginning at least) be able to diagnose
availability or connectivity issues.  But it should be able to catch
some misconfigurations before they lead to catastrophic failure of
the deployment.
