---
tags: openshift, testing
---

# Testing changes on live OpenShift nodes

I have been hacking on the [`runc`][runc] container runtime.  So how
do I test my changes in an OpenShift cluster?

One option is to compose a *machine-os-content* release via
[*coreos-assembler*](https://github.com/coreos/coreos-assembler).
Then you can deploy or upgrade a cluster with that release.  This is
a heavyweight and time consuming option.  I haven't actually tried
it yet.  But it seems like it could be useful for publishing
modified versions for others to test.

For development I want a more lightweight approach.  In this post
I'll demonstrate how to use `rpm-ostree usroverlay` to test changes
on a running OpenShift node.

[runc]: https://github.com/opencontainers/runc

## Background

OpenShift runs on CoreOS.  CoreOS uses [*OSTree*][ostree] to manage
the filesystem.  Most of the filesystem is immutable.  When
upgrading, a new filesystem is prepared before rebooting the system.
The old filesystem is preserved, so it is easy to roll back.

[ostree]: https://en.wikipedia.org/wiki/OSTree

So I can't just log onto an OpenShift node and replace
`/usr/bin/runc` with my modified version.  Nevertheless, I have seen
[references][] to the `rpm-ostree usroverlay` command.  It is
supposed to provide a writable overlayfs on `/usr`, so that you can
test modifications.  Changes are lost upon reboot, but that's fine
for testing.  Let's try it out.

[references]: https://github.com/openshift/machine-config-operator/blob/master/docs/HACKING.md#directly-applying-changes-live-to-a-node

## Overlay via node debug container (doesn't work)

I first attempted to use `rpm-ostree usroverlay` in a node debug
pod.

```shell
% oc debug node/worker-a
Starting pod/worker-a-debug ...
To use host binaries, run `chroot /host`
Pod IP: 10.0.128.2
If you don't see a command prompt, try pressing enter.
sh-4.2# chroot /host
sh-4.4# rpm-ostree usroverlay
Development mode enabled.  A writable overlayfs is now mounted on /usr.
All changes there will be discarded on reboot.
sh-4.4# touch /usr/bin/foo
touch: cannot touch '/usr/bin/foo': Read-only file system
```

The `rpm-ostree usroverlay` command succeeded.  But `/usr` remained
read-only.  The debug container has its own mount namespace, which
was unaffected.  I guess that I need to log into the node directly
to use the writable `/usr` overlay.  Perhaps it is also necessary to
execute `rpm-ostree usroverlay` as an unconfined user (in the
SELinux sense).  I **restarted the node** to begin afresh:

```shell
sh-4.4# reboot

Removing debug pod ...
```


## Overlay via SSH

For the next attempt, I logged into the worker node over SSH.  The
first step was to add the SSH public key to the `core` user's
`authorized_keys` file.  Roberto Carratalá's [helpful blog post][]
explains how to do this.  I will recap the critical bits.

[helpful blog post]: https://rcarrata.com/openshift/update-workers-ssh/

SSH keys can be added via `MachineConfig` objects, which must also
specify the machine role (e.g. `worker`).  The Machine Config
Operator will only add keys to the `core` user.  Multiple keys can
be specified, across multiple `MachineConfig` objects—all the keys
in matching objects will be included.

::: note

I don't have direct network access to the worker node.  So how could
I log in over SSH?  I generated a key ***in the node debug shell***,
and will log in from there!

```shell
sh-4.4# ssh-keygen
Generating public/private rsa key pair.
Enter file in which to save the key (/root/.ssh/id_rsa):
Created directory '/root/.ssh'.
Enter passphrase (empty for no passphrase):
Enter same passphrase again:
Your identification has been saved in /root/.ssh/id_rsa.
Your public key has been saved in /root/.ssh/id_rsa.pub.
The key fingerprint is:
SHA256:jAmv…NMnY root@worker-a
sh-4.4# cat ~/.ssh/id_rsa.pub
ssh-rsa AAAA…4OU= root@worker-a
```

:::

The following `MachineConfig` adds the SSH key for user `core`:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: ssh-authorized-keys-worker
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    passwd:
      users:
      - name: core
        sshAuthorizedKeys:
        - ssh-rsa AAAA…40U= root@worker-a
```

I created the `MachineConfig`:

```shell
% oc create -f machineconfig-ssh-worker.yaml
machineconfig.machineconfiguration.openshift.io/ssh-authorized-keys created
```

In the node debug shell, I observed that Machine Config Operator
applied the change after a few seconds.  It did not restart the
worker node.  My key was added alongside a key defined in some other
`MachineConfig`.

```shell
sh-4.4# cat /var/home/core/.ssh/authorized_keys
ssh-rsa AAAA…jjNV devenv

ssh-rsa AAAA…4OU= root@worker-a
```

Now I could log in over SSH:

```shell
sh-4.4# ssh core@$(hostname)
The authenticity of host 'worker-a (10.0.128.2)' can't be established.
ECDSA key fingerprint is SHA256:LUaZOleqVFunmLCp4/E1naIQ+E5BpmVp0gcsXHGacPE.
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
Warning: Permanently added 'worker-a,10.0.128.2' (ECDSA) to the list of known hosts.
Red Hat Enterprise Linux CoreOS 48.84.202106231817-0
  Part of OpenShift 4.8, RHCOS is a Kubernetes native operating system
  managed by the Machine Config Operator (`clusteroperator/machine-config`).

WARNING: Direct SSH access to machines is not recommended; instead,
make configuration changes via `machineconfig` objects:
  https://docs.openshift.com/container-platform/4.8/architecture/architecture-rhcos.html

---
[core@worker-a ~]$
```

The user is unconfined and I can see the normal, read-only (`ro`)
`/usr` mount (but no overlay):

```shell
[core@worker-a ~]$ id -Z
unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
[core@worker-a ~]$ mount |grep "on /usr"
/dev/sda4 on /usr type xfs (ro,relatime,seclabel,attr2,inode64,logbufs=8,logbsize=32k,prjquota)
overlay on /usr type overlay (rw,relatime,seclabel,lowerdir=usr,upperdir=/var/tmp/ostree-unlock-ovl.KZ4V50/upper,workdir=/var/tmp/ostree-unlock-ovl.KZ4V50/work)
```

I executed `rpm-ostree usroverlay` via `sudo`.  After that, a
read-write (`rw`) overlay filesystem is visible:

```shell
[core@worker-a ~]$ sudo rpm-ostree usroverlay
Development mode enabled.  A writable overlayfs is now mounted on /usr.
All changes there will be discarded on reboot.
[core@worker-a ~]$ mount |grep "on /usr"
/dev/sda4 on /usr type xfs (ro,relatime,seclabel,attr2,inode64,logbufs=8,logbsize=32k,prjquota)
overlay on /usr type overlay (rw,relatime,seclabel,lowerdir=usr,upperdir=/var/tmp/ostree-unlock-ovl.TCPM50/upper,workdir=/var/tmp/ostree-unlock-ovl.TCPM50/work)
```

And it is indeed writable.  I made a copy of the original `runc`
binary, then installed my modified version:

```shell
[core@worker-a ~]$ sudo cp /usr/bin/runc /usr/bin/runc.orig
[core@worker-a ~]$ sudo curl -Ss -o /usr/bin/runc \
    https://ftweedal.fedorapeople.org/runc
```

## Discussion

I achieved my goal of applying local file changes to an OpenShift
node.  The changes are not persistent over reboots.  But I am
testing container runtime changes, so that not a problem.  Indeed,
it is desirable, in case I really mess something up!

To apply changes under `/usr`, I had to log in over SSH.  Because I
did not have direct network access to the worker nodes, I could only
manage this in a convoluted way: generating an SSH key in the node
debug shell, adding the key via a `MachineConfig`, then SSHing from
the debug shell.  I wish there was a less convoluted way to do it.
Maybe there is.  Maybe it's obvious, and I will kick myself when
someone reveals it to me.

In the meantime, I now have a way to deploy a modified `runc`
executable onto my worker nodes.  So I will get on with testing it!
