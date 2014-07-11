Daniel J. Bernstein lecture on software (in)security
====================================================

Building secure software and secure software systems is obviously an
important part of my job as a developer on the `FreeIPA identity
management`_ and `Dogtag PKI`_ projects here at Red Hat.  Last night
I had the privilege of attending a lecture by the renowned Research
Professor `Daniel J. Bernstein`_ at Queensland University of
Technology entitled *Making sure software stays insecure*.  The
abstract of his talk:

  We have to watch and listen to everything that people are doing so
  that we can catch terrorists, drug dealers, pedophiles, and
  organized criminals. Some of this data is sent unencrypted through
  the Internet, or sent encrypted to a company that passes the data
  along to us, but we learn much more when we have comprehensive
  direct access to hundreds of millions of disks and screens and
  microphones and cameras. This talk explains how we've successfully
  manipulated the world's software ecosystem to ensure our
  continuing access to this wealth of data. This talk will not cover
  our efforts against encryption, and will not cover our hardware
  back doors.

Of course, Prof. Bernstein was not the "we" of the abstract.
Rather, the lecture, in its early part, took the form of a thought
experiment suggesting how this manipulation could be taking place.
In the latter part of the lecture, Prof. Bernstein justified and
discussed some security primitives he feels are missing from today's
software.

I will now briefly recount the lecture and the Q&A that followed (a
reconstitution of my handwritten notes; some paraphrase and
omissions have occurred), then wrap up with my thoughts about the
lecture.

.. _FreeIPA identity management: http://www.freeipa.org/page/Main_Page
.. _Dogtag PKI: http://pki.fedoraproject.org/wiki/PKI_Main_Page
.. _Daniel J. Bernstein: http://cr.yp.to/djb.html


Lecture notes
-------------

Introduction
~~~~~~~~~~~~

- Smartphones; almost everyone has one.  Pretty much anyone in the
  world can turn on the microphone or camera and find out what's
  happening.

- It is terrifying that people (authoritarian governments, or, even
  if you trust your goverment now, can you trust the next one?) have
  access to such capabilities.

- Watching everyone, all the time, is not an effective way to catch
  bad guys.  Yes, they are bad, but total surveillance is
  ineffective and violates rights.

- Prof. Bernstein has no evidence of *deliberate* manipulation of
  software ecosystems to this end, but now embarks on a though
  experiment: what if they did try?


Distract users
~~~~~~~~~~~~~~

- Things labelled as "security" but are actually not, e.g.
  anti-virus.

- People are told to do these things, and indeed are happy to follow
  along.  They feel good about doing *something*,

- Money gets spent on e.g. virus scanners or 2014 NIST framework
  compliance, instead of *building secure systems*.  2014 NIST
  definition of "protect" has 98 subcategories, none of which are
  about making secure softare.


Distract programmers
~~~~~~~~~~~~~~~~~~~~

- Automatic low-latency security updates are viewed as a security
  method.

- "Security" is defined by *public security vulnerabilities*.  This
  is *not* security.  The reality is that there are other holes that
  attackers are actively exploiting.


Distract researchers
~~~~~~~~~~~~~~~~~~~~

- Attack papers and competitions are prominent, and research funding
  is often predicated on their outcomes.

- Research into *building* secure systems takes a back seat.


Discourage security
~~~~~~~~~~~~~~~~~~~

- Tell people that "there's no such thing as 100% security, so why
  even try?"

- Tell people that "it is impossible to even define security, so
  give up."

- Some people make both of these claims simultaneously.

- Hide, dismiss or mismeasure *security metric #1* (defined later).

- Prioritise compatibility, "standards", speed, e.g. "an HTTP server
  in the kernel is critical for performance".

Definition of security
~~~~~~~~~~~~~~~~~~~~~~

- *Integrity policy #1*: Whenever a computer shows a file, it also
  tells me the *source* of the file.

- Example: UNIX file ownership and permissions.  Multi-user system,
  no file sharing.  If users are not sharing files, the UNIX model
  if implemented correctly can enforce integrity policy #1.  How can
  we check?

  1. Check the code that enforces the file permission rules.
  2. Check the code that allocates memory, reads and writes files,
     and authenticates users.
  3. Check *all the kernel code* (beacuse it is all privileged).

- The code to check is the *trusted computing base* (TCB).  The size
  of the TCB is *security metric #1*.  It is unnecessary to check or
  limit anything else.

Example: file sharing
~~~~~~~~~~~~~~~~~~~~~

- Eve and Frank need to share files.  Eve can own the file but give
  Frank write permissions.

- By integrity policy #1, the operating system *must* record Frank
  as the source of the file.

- If a process reads data from multiple sources, files written by
  the process must be marked with *all* those sources.

Example: web browsing
~~~~~~~~~~~~~~~~~~~~~

- If you visit Frank's site, browser may *try* to verify and show
  Frank as source of the file(s) being viewed.  But browser TCB is
  *huge*.

- What if instead of current model, you gave Frank a file upload
  account on your system.  Files uploaded could be marked with Frank
  as source.  Browser could then read these files.

- Assuming the OS has this capability, it needn't be manual.  Web
  browsing *could* work this way.

Conclusion
~~~~~~~~~~

- Is the community even *trying* to build a software system with a
  small TCB that enforces integrity policy #1?

Q&A: Identification of sources
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- Cryptography is good for this in networked world, but current CA
  system is "pathetic".

- `Certificate transparency`_ is a PKI consistency-check mechamism
  that may improve current infrastructure.

- A revised infrastructure for obtaining public keys is preferable.
  Prof. Bernstein thinks GNUnet_ is interesting.

- Smaller (i.e. actually auditable) crypto implementations are
  needed.  TweetNaCl_ (pronounced "tweet salt") is a full
  implementation of the NaCl_ cryptography API in 100 tweets.

.. _Certificate transparency: https://en.wikipedia.org/wiki/Certificate_transparency
.. _GNUnet: https://en.wikipedia.org/wiki/GNUnet
.. _TweetNaCl: https://twitter.com/TweetNaCl
.. _NaCl: http://nacl.cr.yp.to/

Q&A: Marking regions of file with different sources
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- I asked a question about whether there was scope within definition
  of *integrity policy #1* for marking *regions* of files with
  different sources, rather than marking a contiguous file with all
  sources.

- Prof. Bernstein suggested that there is, but it would be better to
  change how we are representing that data and decompose it into
  separated files, rather than adding complexity to the TCB.  A
  salient point.


Discussion
----------

This was a thought-provoking and thoroughly enjoyable lecture.  It
was quite narrow in scope, defining and justifying *one* class of
security primitives that Prof. Bernstein believes are essential.
The question of how to *identify* a source did not come up until the
Q&A.  Primitives to enable privacy or anonymity did not come up at
all.  I suppose that by not mentioning them, Prof.  Bernstein was
making the point that they are orthogonal problem spaces (a
sentiment I would agree with).

I should also note that there was no mention of any *integrity
policy #2*, *security metric #2*, or so on.  My interpretation of
this is that Prof.  Bernstein believes that the *#1* definitions are
*sufficient* in the domain of data provenance, but there are other
reasonable interpretations.

The point about keeping the trusted computing base as simple and as
small as possible was one of the big take-aways for me.  His
response to my question implies that he feels it is preferable to
incur costs in complexity and implementation time outside the TCB,
perhaps many times over, in pursuit of the goal of TCB auditability.

Finally, Prof. Bernstein is not alone in lamenting the current trust
model in the PKI of the Internet.  It didn't have a lot to do with
the message of his lecture, but I nevertheless look forward to
learning more about GNUnet and checking out TweetNaCl.
