``staticmethod`` considered beneficial
======================================

Some Python programmers hold that the ``staticmethod`` decorator,
and to a lesser extent ``classmethod``, are to be avoided where
possible.  This view is not correct, and in this post I will explain
why.

This post will be useful to programmers in any language, but
especially Python.

The constructions
-----------------

I must begin with a brief overview of the ``classmethod`` and
``staticmethod`` constructions and their uses.

``classmethod`` is a function that transforms a method into a class
method.  The class method receives the *class object* as its first
argument, rather than an *instance* of the class.  It is typically
used as a method *decorator*:

.. code:: python

  class C:
      @classmethod
      def f(cls, arg1, arg2, ...): ...

By idiom, the class object argument is bound to the name ``cls``.
You can invoke a class method via an instance (``C().f()``) or via
the class object itself (``C.f()``).  In return for this flexibility
you give up the ability to access instance methods or attributes
from the method body, even when it was called via an instance.


``staticmethod`` is nearly identical to ``classmethod``.  The only
difference is that instead of receiving the class object as the
first argument, it does not receive any implicit argument:

.. code:: python

  class C:
      @staticmethod
      def f(arg1, arg2, ...): ...

How are the ``classmethod`` and ``staticmethod`` constructions used?
Consider the following (contrived) class:

.. code:: python

  class Foo(object):

    def __init__(self, delta):
      self.delta = delta

    def forty_two(self):
      return 42

    def answer(self):
      return self.forty_two()

    def modified_answer(self):
      return self.answer() + self.delta


There are some places we could use ``staticmethod`` and
``classmethod``.  Should we?  Let's just do it and discuss the
impact of the changes:

.. code:: python

  class Foo(object):

    def __init__(self, delta):
      self.delta = delta

    @staticmethod
    def forty_two():
      return 42

    @classmethod
    def answer(cls):
      return cls.forty_two()

    def modified_answer(self):
      return self.answer() + self.delta

``forty_two`` became a static method, and it no longer takes any
argument.  ``answer`` became a class method, and its ``self``
argument became ``cls``.  It cannot become a static method, because
it references ``cls.forty_two``.  ``modified_answer`` can't change
at all, because it references an instance attribute
(``self.delta``).  ``forty_two`` could have been made a class
method, but just as it had no need of ``self``, it has no need
``cls`` either.

There is an alternative refactoring for ``forty_two``.  Because it
doesn't reference anything in the class, we could have extracted it
as a top-level function (i.e. defined not in the class but directly
in a module).  Conceptually, ``staticmethod`` and top-level
functions are equivalent modulo namespacing.

Was the change I made a good one?  Well, you already know my answer
will be *yes*.  Before I justify my position, let's discuss some
counter-arguments.

Why not ``staticmethod`` or ``classmethod``?
--------------------------------------------

Most Python programmers accept that alternative constructors,
factories and the like are legitimate applications of
``staticmethod`` and ``classmethod``.  Apart from these
applications, opinions vary.

- For some folks, the above are the *only* acceptable uses.

- Some accept ``staticmethod`` for grouping utility functions
  closely related to some class, into that class; others regard this
  kind of ``staticmethod`` proliferation as a code smell.

- Some feel that anything likely to only ever be called on an
  instance should use instance methods, i.e. having ``self`` as the
  first argument, even when not needed.

- The decorator syntax "noise" seems to bother some people

Guido van Rossum, author and BDFL of Python, `wrote`_ that static
methods were an accident.  History is interesting, sure, but not all
accidents are automatically bad.

.. _wrote: https://mail.python.org/pipermail/python-ideas/2012-May/014969.html

I am sympathetic to some of these arguments.  A class with a lot of
static methods might just be better off as a module with top-level
functions.  It is true that ``staticmethod`` is not required for
anything whatsoever and could be dispensed with (this is not true of
``classmethod``).  And clean code is better than noisy code.  Surely
if you're going to clutter your class with decorators, you want
something in return right?  Well, you do get something in return.


Deny thy ``self``
-----------------

Let us put to the side the side-argument of ``staticmethod`` versus
top-level functions.  The real debate is *instance methods* versus
*not instance methods*.  This is the crux.  Why avoid instance
methods (where possible)?  Because doing so is a win for
readability.

Forget the contrived ``Foo`` class from above and imagine you are in
a non-trivial codebase.  You are hunting a bug, or maybe trying to
understand what some function does.  You come across an interesting
function.  It is 50 lines long.  What does it do?

If you are reading an instance method, in addition to its arguments,
the module namespace, imports and builtins, it has access to
``self``, the instance object.  If you want to know what the
function does or doesn't do, you'll have to read it.

But if that function is a ``classmethod``, you now have *more
information* about this function—namely that it cannot access any
instance methods, even if it was invoked on an instance (including
from within a sibling instance method).  ``staticmethod`` (or a
top-level function) gives you a bit more than this: not even class
methods can be accessed (unless directly referencing the class,
which is easily detected and definitely a code smell).  By using
these constructions when possible, the programmer has less to think
about as they read or modify the function.

You can flip this scenario around, too.  Say you know a program is
failing in some *instance* method, but you're not sure how the
problematic code is reached.  Well, you can rule out the class
methods and static methods straight away.

These results are similar to the result of `parametricity`_ in
programming language theory.  The profound and *actionable*
observation in both settings is this: knowing *less* about something
gives the programmer *more* information about its behaviour.

.. _parametricity: http://citeseer.ist.psu.edu/viewdoc/download;jsessionid=F63444BB6DD3E18607EA7B3677036F09?doi=10.1.1.38.9875&rep=rep1&type=pdf

These might not seem like big wins.  Because most of the time it's
only a small win.  But it's never a lose, and over the life of a
codebase or the career of a programmer, the small readability wins
add up.  To me, this is a far more important goal than avoiding
extra lines of code (decorator syntax), or spurning a feature
because its author considers it an accident or it transgresses the
`Zen of Python`_ or whatever.

.. _Zen of Python: https://www.python.org/dev/peps/pep-0020/

But speaking of the Zen of Python...

    Readability counts.

So use ``classmethod`` or ``staticmethod`` wherever you can.
