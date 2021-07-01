---
tags: openshift, testing
---

# Live-testing changes in OpenShift clusters

I have been hacking on the [`runc`][runc] container runtime.  So how
do I test my changes in an OpenShift cluster?

One option is to compose a `machine-os-content` release via
[*coreos-assembler*](https://github.com/coreos/coreos-assembler).
Then you can deploy or upgrade a cluster with that release.  Indeed,
this approach is *necessary* for testing installation and upgrades.
It also seems useful for publishing modified versions for other
people to test.  But it is a heavyweight and time consuming option.

For development I want a more lightweight approach.  In this post
I'll demonstrate how to use the `rpm-ostree usroverlay` and
`rpm-ostree override replace` commands to test changes in a live
OpenShift cluster.

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
for testing.

There's also the `rpm-ostree override replace …` command.  This
command works on the level of RPM packages.  It allows you to
install new packages or replace or remove packages.  Changes persist
across reboots, but it is easy to roll back to the *pristine* state
of the current CoreOS release.

The rest of this article explores how to use these two commands to
apply changes to the cluster.

[references]: https://github.com/openshift/machine-config-operator/blob/master/docs/HACKING.md#directly-applying-changes-live-to-a-node

## `usroverlay` via debug container (doesn't work)

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


## `usroverlay` via SSH

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

## Digression: use a buildroot

The `runc` executable I installed on the previous step didn't work.
I had built it on my workstation, against a too-new version of
*glibc*.  The OpenShift node (which was running RHCOS 4.8, based on
RHEL 8.4) was unable to link `runc`.  Therefore it could not run
*any* container workloads.  I was able to SSH in from another node
and reboot, discarding the transient change in the `usroverlay` and
restoring the node to a functional state.

All of this is obvious in hindsight.  You have to build the program
for the environment in which it will be executed.  In my case, it
was easiest to do this via Brew or Koji.  I cloned the dist-git
repository (via the `fedpkg` or `rhpkg` tool), created patches and
updated the `runc.spec` file.  Then I built the SRPM (`.src.rpm`)
and started a scratch build in Brew.  After the build completed I
made the resulting `.rpm` publicly available, so that it can be
fetched from the OpenShift cluster.

## `override replace` via node debug container

I now have my modified `runc` in an RPM package.  So I can use
`rpm-ostree override replace` to install it.  In a debug node on the
host:

```shell
sh-4.4# rpm-ostree override replace \
  https://ftweedal.fedorapeople.org/runc-1.0.0-98.rhaos4.8.gitcd80260.el8.x86_64.rpm
Downloading 'https://ftweedal.fedorapeople.org/runc-1.0.0-98.rhaos4.8.gitcd80260.el8.x86_64.rpm'... done!
Checking out tree eb6dd3b... done
No enabled rpm-md repositories.
Importing rpm-md... done
Resolving dependencies... done
Applying 1 override
Processing packages... done
Running pre scripts... done
Running post scripts... done
Running posttrans scripts... done
Writing rpmdb... done
Writing OSTree commit... done
Staging deployment... done
Upgraded:
  runc 1.0.0-97.rhaos4.8.gitcd80260.el8 -> 1.0.0-98.rhaos4.8.gitcd80260.el8
Run "systemctl reboot" to start a reboot
```

`rpm-ostree` downloaded the package and prepared the updated OS.
Per the advice, the update is not active yet; I need to reboot:

```shell
sh-4.4# rpm -q runc
runc-1.0.0-97.rhaos4.8.gitcd80260.el8.x86_64
sh-4.4# systemctl reboot
sh-4.4# exit
sh-4.2# 
Removing debug pod ...
```

After reboot I started a node debug container and verified that the
modified version of `runc` is visible:

```shell
% oc debug node/worker-a
Starting pod/worker-a-debug ...
To use host binaries, run `chroot /host`
Pod IP: 10.0.128.2
If you don't see a command prompt, try pressing enter.
sh-4.2# chroot /host
sh-4.4# rpm -q runc
runc-1.0.0-98.rhaos4.8.gitcd80260.el8.x86_64
```

And the fact that the debug container is working proves that the
modified version of runc isn't *completely* broken!  Testing the new
functionality is a topic for a different post, so I'll leave it at
that.

### Listing and resetting overrides

`rpm-ostree status --booted` lists the current base image and any
overrides that have been applied:

```shell
sh-4.4# rpm-ostree status --booted
State: idle
BootedDeployment:
* pivot://quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:9a23adde268dc8937ae293594f58fc4039b574210f320ebdac85a50ef40220dd
              CustomOrigin: Managed by machine-config-operator
                   Version: 48.84.202106231817-0 (2021-06-23T18:21:06Z)
      ReplacedBasePackages: runc 1.0.0-97.rhaos4.8.gitcd80260.el8 -> 1.0.0-98.rhaos4.8.gitcd80260.el8
```

To reset an override for a specific package, run `rpm-ostree
override reset $PKG`:

```shell
sh-4.4# rpm-ostree override reset runc
Staging deployment... done
Freed: 1.1 GB (pkgcache branches: 0)
Downgraded:
  runc 1.0.0-98.rhaos4.8.gitcd80260.el8 -> 1.0.0-97.rhaos4.8.gitcd80260.el8
Run "systemctl reboot" to start a reboot
```

To reset *all* overrides, execute `rpm-ostree reset`:

```shell
sh-4.4# rpm-ostree reset
Staging deployment... done
Freed: 54.8 MB (pkgcache branches: 0)
Downgraded:
  runc 1.0.0-98.rhaos4.8.gitcd80260.el8 -> 1.0.0-97.rhaos4.8.gitcd80260.el8
Run "systemctl reboot" to start a reboot
```

## Discussion

I achieved my goal of installed a modified `runc` executable on an
OpenShift node.  There were two approaches:

1. `rpm-ostree usroverlay` creates a writable overlay on `/usr`.
   The overlay disappears at reboot, which is fine for my testing
   needs.  This technique doesn't work from a node debug container;
   you have to log in over SSH, which requires additional steps to
   add SSH keys.

2. `rpm-ostree override replace` overrides a particular package RPM.
   The change takes effect after reboot and is persistent.  It is
   easy to rollback or reset the override.  This technique does not
   require SSH login; it works fine in a node debug container.

Because I needed to build my package in a RHEL 8.4 / RHCOS 4.8
buildroot, I used Brew.  The build artifacts are RPMs.  Therefore
`rpm-ostree override replace` is the most convenient option for me.

Both options apply changes *per-node*.  After confirming with CoreOS
developers, there is currently no way to roll out a package override
cluster-wide or to a defined group of nodes (e.g. to
`MachineConfigPool/worker` via a `MachineConfig`).  So for now, you
either have to apply changes/overrides on specific nodes, or build
the whole `machine-os-content` image and upgrade the cluster.  As a
container runtime developer, my sweet spot is in a gulf between the
existing options.  I can tolerate this mild annoyance on the
assumption that it discourages messing around in production
environments.

In the meantime, now that I have worked out how to install my
modified `runc` onto worker nodes, I will get on with testing it!
