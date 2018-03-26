Can we teach an old Dogtag new tricks?
======================================

Dogtag is a very old program.  It started at *Netscape*.  It is old
enough to vote.  Most of it was written in the early days of Java,
long before generics or first-class functions.  A lot of it has
hardly been touched since it was first written.

Old code often follows old practices that are no longer reasonable.
This is not an indictment on the original programmers!  The
capabilities of our tools usually improves over time (certainly true
for Java).  The way we solve problems often improves over time too,
through better libraries and APIs.  And back in the '90s sites like
Stack Overflow didn't exist and there wasn't as much free software
to learn from.  Also, observe that Dogtag is still here, 20 years
on, used by customers and being actively developed.  This is a
*huge credit* to the original developers and everyone who worked on
Dogtag in the meantime.

But we cannot deny that today we have a lot of very old Java code
that follows outdated practices and is difficult to reason about and
maintain.  And maintain it we must.  Bugs must be fixed, and new
features will be developed.  Can Dogtag's code be modernised?
*Should it* be modernised?


Costs of change, costs of avoiding change
-----------------------------------------

One option is to accept and embrace the status quo.  Touch the old
code as little as possible.  Make essential fixes only.  Do not
refactor classes or interfaces.  When writing new code, use the
existing interfaces, even if they allow (or demand) unsafe use.

There is something to be said for this approach.  Dogtag has bugs,
but it is "battle hardened".  It is used by large organisations in
security-critical infrastructure.  Changing things introduces a risk
of breaking things.  The bigger the change, the bigger the risk.
And Dogtag users are some of the biggest, most security-conscious
and risk-conscious organisations out there.

On the other hand, persisting with the old code has some drawbacks
too.  First, there are certainly undiscovered bugs.  Avoiding change
except when there is a known defect means those bugs will stay
hidden—until they manifest themselves in an unpleasant way!  Second,
old interfaces that require, for example, unsafe mutation of
objects, can lead to new bugs when we do fix bugs or implement new
features.  Finally, existing code that is difficult to reason about,
and interfaces that are difficult to use, slow down fixes and new
development.


Case study: ACLs
----------------

Dogtag uses *access control lists (ACLs)* to govern what users can
do in the system.  An ACL is represented in text thus (wrapping for
presentation):

::

  certServer.ca.authorities
    :create,modify
    :allow (list,read) user="anybody"
      ;allow (create,modify,delete) group="Administrators"
    :Administrators may create and modify lightweight authorities

The fields are:

1. Name of the ACL
2. List of permissions covered by the ACLs
3. List of ACL entries.  Each entry either grants or denies the
   listed permissions to users matching an expression
4. Comment

The above ACL grants lightweight CA read permission to all users,
while only members of the ``Administrators`` group can create,
modify or delete them.  A typical Dogtag CA subsystem might have
around 60 such ACLs.  The *authorisation subsystem* is responsible
for loading and enforcing ACLs.

I have touched the ACL machinery a few times in the last couple of
years.  Most of the changes were bug fixes but I also implemented a
small enhancement for merging ACLs with the same name.  These were
tiny changes; most ACL code is unchanged from prehistoric (pre-Git
repo) times.  The implementation has several significant issues.
Let's look at a few aspects.

Broken parsing
~~~~~~~~~~~~~~

The ``ACL.parseACL`` method
(`source <https://github.com/dogtagpki/pki/blob/223e6980c3f3f7a075890897bbb74140cb95279a/base/common/src/com/netscape/certsrv/acls/ACL.java#L191-L289>`_)
converts the textual representation of an ACL into an internal
representation.  It's about 100 lines of Java.  Internally it calls
``ACLEntry.parseACLEntry`` which is another 40 lines.

The implementation is ad-hoc and inflexible.  Fields are
found by scanning for delimiters, and their contents are handled in
a variety of ways.  For fields that can have multiple values,
``StringTokenizer`` is used, as in the following (simplified)
example:

.. code:: java

  StringTokenizer st = new StringTokenizer(entriesString, ";");
  while (st.hasMoreTokens()) {
      String entryString = st.nextToken();
      ACLEntry entry = ACLEntry.parseACLEntry(acl, entryString);
      if (entry == null)
          throw new EACLsException("failed to parse ACL entries");
      entry.setACLEntryString(entryString);
      acl.entries.add(entry);
  }

So what happens if you have an ACL like the following?
Note the semicolon in the group name.

::

  certificate:issue:allow (read) group="sysadmin;pki"
    :PKI sysadmins can read certificates

The current parser will either fail, or succeed but yield an ACL
that makes no sense (I'm not quite sure which).  I found a similar
issue in real world use where group names contained a colon.  The
parser was scanning forward for a colon to determine the end of the
ACL entries field:

.. code:: java

  int finalDelimIdx = unparsedInput.indexOf(":");
  String entriesString = unparsedInput.substring(0, finalDelimIdx);

This was fixed by scanning backwards from the end of the string for
the final colon:

.. code:: java

  int finalDelimIdx = unparsedInput.lastIndexOf(":");
  String entriesString = unparsedInput.substring(0, finalDelimIdx);

Now colons in group names work as expected.  But it is broken in a
different way: if the comment contains a colon, parsing will fail.
These kinds of defects are symptomatic of the ad-hoc, brittle parser
implementation.


Incomplete parsing
~~~~~~~~~~~~~~~~~~

``ACLEntry.parseACLEntry`` method does not actually parse the access
expressions.  An ACL expression can look like::

  user="caadmin" || group="Administrators"

The expression is saved in the ``ACLEntry`` as-is.  Parsing is
deferred to ACL evaluation.  Parsing work is repeated every time the
entry is evaluated.  The deferral also means that invalid
expressions are silently allowed and can only be noticed when they
are evaluated.  The effect of an invalid expression depends on the
kind of syntax error, and the behaviour of the access evaluator.


Access evaluator expressions
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The code that parses access evaluator expressions (e.g.
``user="bob"``) will accept any of ``=``, ``!=``, ``>`` or ``<``,
even when the nominated access evaluator does not handle the given
operator.  For example, ``user>"bob"`` will be accepted, but the
``user`` access evaluator only handles ``=`` and ``!=``.  It is up
to each access evaluator to handle invalid operators appropriately.
This is a burden on the programmer.  It's also confusing for users
in that semantically invalid expressions like ``user>"bob"`` do not
result in an error.

Furthermore, the set of access evaluator operators is not
extensible.  Dogtag administrators can write their own access
evaluators and configure Dogtag to use them.  But these can only use
the ``=``, ``!=``, ``>`` or ``<`` operators.  If you need more than
four operators, need non-binary operators, or would prefer different
operator symbols, too bad.


ACL evaluation
~~~~~~~~~~~~~~

The ``AAclAuthz`` class
(`source <https://github.com/dogtagpki/pki/blob/223e6980c3f3f7a075890897bbb74140cb95279a/base/server/cms/src/com/netscape/cms/authorization/AAclAuthz.java>`_)
contains around 400 lines of code for evaluating an ACLs for a given
user and permissions.  (This includes the expression parsing
discussed above).  In addition, the typical access evaluator class
(``UserAccessEvaluator``, ``GroupAccessEvaluator``, etc.) has about
20 to 40 lines of code dealing with evaluation.  The logic is not
straightforward to follow.

There is at least one major bug in this code.  There is a global
configuration that controls whether an ACL's *allow* rules or *deny*
rules are processed first.  The default is *deny,allow*, but if you
change it to *allow,deny*, then a matching *allow* rule will cause
denial!  Observe (example simplified and commentary added by me):

.. code:: java

    if (order.equals("deny")) {
        // deny,allow, the default
        entries = getDenyEntries(nodes, perm);
    } else {
        // allow,deny
        entries = getAllowEntries(nodes, perm);
    }

    while (entries.hasMoreElements()) {
        ACLEntry entry = entries.nextElement();
        if (evaluateExpressions(
                authToken,
                entry.getAttributeExpressions())) {
            // if we are in allow,deny mode, we just hit
            // a matching *allow* rule, and deny access
            throw new EACLsException("permission denied");
        }
    }


The next step of this routine is to process the next set of rules.
Like above, if we are in *allow,deny* mode and encounter a matching
*deny* rule, access will be granted.

This is a serious bug!  It completely reverses the meaning of ACLs.
In most cases the environment will be completely broken.  It also
poses a security issue.  Because of how broken this setting is, the
Dogtag team thinks that it's unlikely that anyone is running in
*allow,deny* mode.  But we can't be sure, so the bug was assigned
`CVE-2018-1080`_.

.. _CVE-2018-1080: https://bugzilla.redhat.com/show_bug.cgi?id=1556657

This defect is present in the initial commit in the Dogtag Git
repository (2008).  It might have been presented in the original
implementation.  But whenever it was introduced, the problem was not
noticed.  Several developers who made small changes over the years
to the ACL code (logging, formatting, etc) did not notice it.
Including me, until very recently.

How has this bug existed for so long?  There is not one single
reason, but contributing factors could be:

- Lack of tests, or at least lack of testing in *allow,deny* mode

- Verbose, hard to read code makes it hard to notice a bug that
  might be more obvious in "pseudo-code".

- `Boolean blindness`_.  A boolean is just a bit, divorced from the
  context that constructed it.  This can lead to misinterpretation.
  In this case, the boolean result of ``evaluateExpressions`` was
  misinterpreted as *allow|deny*; the correct interpretation is
  *match|no-match*.

- Lack of code review.  Perhaps peer code review was not practiced
  when the original implementation was written.  Today all patches
  are reviewed by another Dogtag developer before being merged (we
  use `Gerrit <https://www.gerritcodereview.com/>`_ for that).
  There is a chance (but not a guarantee) we might have noticed that
  bug.  Maybe a systematic review of old code is warranted.

.. _Boolean blindness: https://existentialtype.wordpress.com/2011/03/15/boolean-blindness/


A better way?
-------------

So, looking at one small but important part of Dogtag, we see an
old, broken implementation.  Some of these problems can be fixed
easily (the *allow,deny* bug).  Others require more work (fixing the
parsing, extensible access evaluator operators).

Is it worth fixing the non-critical issues?  Taking Java as an
assumption, it is debatable.  The implementation could be cleaned
up, type safety improved, bugs fixed.  But Java being what it is,
even if a lot of the parsing complexity was handled by libraries,
the result would still be fairly verbose.  Readability and
maintainability would still be limited, because of the limitations
of Java itself.

So let's refine our assumption.  Instead of *Java*, we will assume
*JVM*.  This opens up to us a bunch of languages that target the
JVM, and libraries written using those languages.  Dogtag will
probably never leave the JVM, for various reasons.  But there's no
technical reason we can't replace old, worn out parts made of Java
with new implementations written using languages that have more to
offer in terms of correctness, readability and maintainability.

There are `many languages`_ that target the JVM and interoperate
with Java.  One such language is `Haskell
<https://www.haskell.org/>`_, an advanced, pure functional
programming (FP) language.  JVM support for Haskell comes in the
guise of `Eta <https://eta-lang.org/>`_.  Eta is a fork of GHC (the
most popular Haskell compiler) version 7.10, so any pure Haskell
code that worked with GHC 7.10 will work with Eta.  I won't belabour
any more gory details of the toolchain right now. Instead, we can
dive right into a prototype of ACLs written in Haskell/Eta.

.. _many languages: https://en.wikipedia.org/wiki/List_of_JVM_languages


I Haskell an ACL
----------------

I assembled a Haskell prototype
(`source code <https://github.com/frasertweedale/notes-redhat/tree/master/fp-examples/acl>`_)
of the ACL machinery in one day.  Much of this time was spent
reading the Java implementation so I could preserve its semantics.

The prototype is not complete.  It does not support serialisation of
ACLs or the heirarchical nature of ACL evaluation (i.e. checking an
authorisation on resource ``foo.bar.baz`` would check ACLs named
``foo.bar.baz``, ``foo.bar`` and ``foo``).  But it does support
parsing and evaluation, and it fixes all the problems mentioned
earlier: parsing bugs, non-extensible or mismatched access evaluator
operators, invalid expressions accepted by main parser.

The implementation is about 250 lines of code, roughly ⅓ the size of
the Java implementation.  It is much easier to read and reason
about.  Let's look at a few highlights.

The definitions of the ``ACL`` data type, and its constituents, are
straightforward:

.. code:: haskell

  type Permission = Text  -- type synonym, for convenience

  data ACLRuleType = Allow | Deny
    deriving (Eq) -- auto-derive an equality
                  -- test (==) for this type

  -- a record type with 3 fields
  data ACLRule = ACLRule
    { aclRuleType :: ACLRuleType
    , aclRulePermissions :: [Permission]
    , aclRuleExpression :: ACLExpression
    }

  data ACL = ACL
    { aclName :: Text
    , aclPermissions :: [Permission]
    , aclRules :: [ACLRule]
    , aclDescription :: Text
    }

The definition of the ACL parser follows the structure of the data
type.  This aids readability and assists reasoning about
correctness:

.. code:: haskell

  acl :: [Parser AccessEvaluator] -> Parser ACL
  acl ps = ACL
    <$> takeWhile1 (/= ':') <* char ':'
    <*> (permission `sepBy1` char ',') <* char ':'
    <*> (rule ps `sepBy1` spaced (char ';')) <* char ':'
    <*> takeText

Each line is a parser for one of the fields of the ``ACL`` data
type.  The ``<$>`` and ``<*>`` *infix* functions combine these
smaller parsers into a parser for the whole ``ACL`` type.
``permission`` and ``rule`` are parsers for the ``Permission`` and
``ACLRule`` data types, respectively.  The ``sepBy1`` combinator
turns a parser for a single thing into a parser for a list of
things.

Note that several of these *combinators* are not specific to parsers
but are derived from, or part of, a common abstraction that parsers
happen to inhabit.  The actual parser library used is incidental.  A
simple parser type and all the combinators used in this ACL
implementation, written from scratch, would take all of 50 lines.

The ``[Parser AccessEvaluator]`` argument (named ``ps``) is a list
of parsers for ``AccessEvaluator``.  This provides the access
evaluator extensibility we desire while ensuring that invalid
expressions are rejected.  The details are down inside the
implementation of ``rule`` and are not discussed here.

Next we'll look at how ACLs are evaluated:

.. code:: haskell

  data ACLRuleOrder = AllowDeny | DenyAllow

  data ACLResult = Allowed | Denied

  evaluateACL
    :: ACLRuleOrder
    -> AuthenticationToken
    -> Permission
    -> ACL
    -> ACLResult
  evaluateACL order tok perm (ACL _ _ rules _ ) =
    fromMaybe Denied result  -- deny if no rules matched
    where
      permRules =
        filter (elem perm . aclRulePermissions) rules

      orderedRules = case order of
        DenyAllow -> denyRules <> allowRules
        AllowDeny -> allowRules <> denyRules
      denyRules =
        filter ((== Deny) . aclRuleType) permRules
      allowRules =
        filter ((== Allow) . aclRuleType) permRules

      -- the first matching rule wins
      result = getFirst
        (foldMap (First . evaluateRule tok) orderedRules)

Given an ``ACLRuleOrder``, an ``AuthenticationToken`` bearing user
data, a ``Permission`` on the resource being accessed and an ``ACL``
for that resource, ``evaluateACL`` returns an ``ACLResult`` (either
``Allowed`` or ``Denied``.  The implementation filters rules for the
given permission, orders the rules according to the
``ACLRuleOrder``, and returns the result of the first matching rule,
or ``Denied`` if no rules were matched.

.. code:: haskell

  evaluateRule
    :: AuthenticationToken
    -> ACLRule
    -> Maybe ACLResult
  evaluateRule tok (ACLRule ruleType _ expr) =
    if evaluateExpression tok expr
      then Just (result ruleType)
      else Nothing
    where
      result Deny = Denied
      result Allow = Allowed

Could the *allow,deny* bug from the Java implementation occur here?
It cannot.  Instead of the rule evaluator returning a ``boolean`` as
in the Java implementation, ``evaluateRule`` returns a ``Maybe
ACLResult``.  If a rule does not match, its result is ``Nothing``.
If it does match, the result is ``Just Denied`` for ``Deny`` rules,
or ``Just Allowed`` for ``Allow`` rules.  The first ``Just`` result
encountered is used directly.  It's still possible to mess up the
implementation, for example:

.. code:: haskell

    result Deny = Allowed
    result Allow = Deny

But this kind of error is less likely to occur and more likely to be
noticed.  Boolean blindness is not a factor.


Benefits of FP for prototyping
------------------------------

There are benefits to using functional programming for prototyping
or re-implementing parts of a system written in less expressive
langauges.

First, a tool like Haskell lets you express the nature of a problem
succinctly, and leverage the type system as a design tool as you
work towards a solution.  The solution can then be translated into
Java (or Python, or whatever).  Because of the less powerful (or
nonexistent) type system, there will be a trade-off.  You will
either have to throw away some of the type safety, or incur
additional complexity to keep it (how much complexity depends on the
target language).  It would be better if we didn't have to make this
trade-off (e.g. by using Eta).  But the need to make the trade-off
does not diminish the usefulness of FP as a design tool.

It's also a great way of learning about an existing part of Dogtag,
and checking assumptions.  And for finding bugs, and opportunities
for improving type safety, APIs or performance.  I learned a lot
about Dogtag's ACL implementation by reading the code to understand
the problem, then solving the problem using FP.  Later, I was able
to translate some aspects of the Haskell implementation (e.g. using
unary sum types to represent ACL rule types and the evaluation order
setting) back into the Java implementation (as ``enum`` types).
This improved type safety and readability.

Going forward, for significant new code and for fixes or
refactorings in isolated parts of Dogtag's implementation, I will
spend some time representing the problems and designing solutions in
Haskell.  The resulting programs will be useful artifacts in their
own right; a kind of documentation.


Where to from here?
-------------------

I've demonstrated some of the benefits of the Haskell implementation
of ACLs.  If the Dogtag development team were to agree that we
should begin using FP in Dogtag itself, what would the next steps
be?

Eta is not yet packaged for Fedora, let alone RHEL.  So as a first
step we would have to talk to product managers and release engineers
about bringing Eta into RHEL.  This is probably the biggest hurdle.
One team asking for a large and rather green toolchain that's not
used anywhere else (yet) to be brought into RHEL, where it will have
to be supported forever, is going to raise eyebrows.

If we clear that hurdle, then comes the work of packaging Eta.
Someone (me) will have to become the package mantainer.  And by the
way, Eta is written in (GHC) Haskell, so we'll also need to package
GHC for RHEL (or RHEL-extras).  Fortunately, GHC *is* packaged for
Fedora, so there is less to do there.

The final stage would be integrating Eta into Dogtag.  The build
system will need to be updated, and we'll need to work out how we
want to use Eta-based functions and objects from Java (and
vice-versa).  For the ACLs system, we might want to make the old and
new implementations available side by side, for a while.  We could
even run both implementations simultaneously in a *sanity check*
mode, checking that results are consistent and emitting a warning
when they diverge.


Conclusion
----------

This post started with a discussion of the costs and risks of making
(or avoiding) significant changes in a legacy system.  We then
looked in detail at the ACLs implementation in Dogtag, noting some
of its problems.

We examined a prototype (re)implementation of ACLs in *Haskell*,
noting several advantages over the legacy implementation.  FP's
usefulness as a design tool was discussed.  Then we discussed the
possibility of using FP in Dogtag itself.  What would it take to
start using Haskell in Dogtag, via the *Eta* compiler which targets
the JVM?  There are several hurdles, technical and non-technical.

Is it worth all this effort, just to be in a position where we can
(re)write even a small component of Dogtag in a language other than
Java?  A language that assists the programmer in writing correct,
readable and maintainable software?  In answering this question, the
costs and risks of persisting with legacy languages and APIs must be
considered.  I believe the answer is "yes".
