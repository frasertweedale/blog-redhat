---
tags: sysadmin
---

More entropy with ``haveged``
=============================

When a system's entropy pool is depleted, reads from ``/dev/random``
will block.  For applications that require lots of entropy, in
environments where little entropy is available, long delays can
result.

A side-note: on Linux, information about the amount of entropy
available can be found under ``/proc/sys/kernel/random/``, along
with other parameters of the kernel entropy device and a UUID
source.  Be aware that other systems may not have this interface.

So if you *are* running out of entropy, what can you do?  The
haveged_ program exists to remedy this problem.  It implements a
variant of the HAVEGE_ (**HA**rdware **V**olatile **E**ntropy
**G**athering and **E**\xpansion) algorithm.  In brief, HAVEGE
leverages the fact that modern processors have thousands of bits of
volatile internal state that affect how long it takes to execute
particular routines.  The nondeterminism in the time taken to
execute a particular routine, also known as *flutter*, can be
determined by reading the hardware clock counter.  Using this
entropy to seed a PRNG, HAVEGE can provide orders of magnitude more
entropy than the standard Linux entropy device.

.. _haveged: http://www.issihosts.com/haveged/
.. _HAVEGE: http://www.irisa.fr/caps/projects/hipsor/

Let's install ``haveged`` and see it in action::

  sudo yum install -y haveged
  sudo systemctl start haveged.service

That's all there is to it.  This runs ``/usr/sbin/haveged -w 1024 -v
1 --Foreground``.  The ``-w`` argument specifies the *write wakeup
threshold*.  When ``/dev/random`` has fewer than this many bits of
entropy available, processes writing to the entropy pool are
awakened.  ``haveged`` wakes up, produces some entropy and feeds it
to Linux for other applications to use.

The availability and quality of entropy can be tested using the
``rngtest`` tool, available in the ``rng-tools`` package.  Compare
running ``cat /dev/random | rngtest -c 1000`` both with and without
``haveged`` working to feed ``/dev/random``.  You should find that
``haveged`` does a good job of ensuring ample entropy is available
for programs.

`Another solution`_ to low entropy on Linux is ``rngd``, which works
similarly to ``haveged`` but reads entropy from hardware RNGs.  Of
course, you need a hardware RNG for ``rngd`` to be effective.  The
default location for a hardware RNG is ``/dev/hwrandom``; ``rngd``
uses this device by default but can be configured to use any device
that provides the Linux ``/dev/random`` ioctl API.  Some Linux
distributions (including recent releases of Fedora) ship with
``rngd`` enabled by default.

.. _Another solution: http://www.issihosts.com/haveged/history.html#other

Let it again be noted that the entropy devices provided by other
operating systems may (read: *do*) operate differently from the
Linux entropy device, and some have native support for hardware RNGs
when present, so while the approach to entropy replenishment shared
by ``haveged`` and ``rngd`` works well for Linux, it may be
incorrect or simply unnecessary for other systems.
