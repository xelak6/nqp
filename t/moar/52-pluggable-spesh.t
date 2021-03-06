#!/usr/bin/env nqp

# Tests for extending the MoarVM specializer to guard on new kinds of things
# from NQP. 

plan(66);

{
    # Minimal test case: under no threaded contention, should run the resolve just
    # once per time it statically appears provided the guard is met.
    my $times-run := 0;
    nqp::speshreg('nqp', 'assume-pure', -> $code {
        $times-run++;
        nqp::speshguardobj($code);
        $code()
    });
    my $a := 100;
    sub assumed-pure() { $a }
    my $total := 0;
    for 1,2,3 {
        $total := $total + nqp::speshresolve('assume-pure', &assumed-pure);
        $a++;
    }
    ok($times-run > 0, 'Ran the spesh plugin');
    ok($times-run == 1, 'Ran the spesh registered block once per static resolve');
    ok($total == 300, 'Correct cached result of the spesh reg');

    # Check things work correctly with multiple positions.
    $times-run := 0;
    $a := 100;
    sub multiple_test() {
        my $x := nqp::speshresolve('assume-pure', &assumed-pure);
        $a++;
        my $y := nqp::speshresolve('assume-pure', &assumed-pure);
        $a++;
        my $z := nqp::speshresolve('assume-pure', &assumed-pure);
        $a++;
        return $x + $y + $z;
    }
    $total := 0;
    for 1,2,3 {
        $total := $total + multiple_test();
    }
    ok($times-run == 3, 'Ran resolver once per bytecode location');
    ok($total == 3 * (100 + 101 + 102), 'Got correct cached results');

    # Check that the object guard is enforced.
    sub assumed-pure-b() { 2 * $a }
    sub assumed-pure-c() { 3 * $a }
    $times-run := 0;
    $a := 100;
    sub purify(&target) {
        nqp::speshresolve('assume-pure', &target)
    }
    ok(purify(&assumed-pure) == 100, 'Exact object guard honored on first call (1)');
    ok(purify(&assumed-pure-b) == 200, 'Exact object guard honored on first call (2)');
    ok(purify(&assumed-pure-c) == 300, 'Exact object guard honored on first call (3)');
    $a++;
    ok(purify(&assumed-pure) == 100, 'Exact object guard matches on second call (1)');
    ok(purify(&assumed-pure-b) == 200, 'Exact object guard matches on second call (2)');
    ok(purify(&assumed-pure-c) == 300, 'Exact object guard matches on second call (3)');
    ok($times-run == 3, 'Resolve ran once per distinct guard match even at same position');
}

# Concrete, non-concrete, and type guards
{
    my $times-run := 0;
    nqp::speshreg('nqp', 'type-and-definedness-counter', -> $obj {
        nqp::speshguardtype($obj, $obj.WHAT);
        nqp::isconcrete($obj)
            ?? nqp::speshguardconcrete($obj)
            !! nqp::speshguardtypeobj($obj);
        ++$times-run
    });
    sub test($obj) {
        nqp::speshresolve('type-and-definedness-counter', $obj)
    }
    my class A {}
    my class B {}
    ok(test(A) == 1, 'First run with A type object is correct result');
    ok(test(A) == 1, 'Second run with A type object gets same result');
    ok(test(B) == 2, 'First run with B type object is correct result');
    ok(test(B) == 2, 'Second run with B type object gets same result');
    ok(test(A.new) == 3, 'First run with A instance is correct result');
    ok(test(A.new) == 3, 'Second run with A instance gets same result');
    ok(test(B.new) == 4, 'First run with B instance is correct result');
    ok(test(B.new) == 4, 'Second run with B instance gets same result');
    ok(test(A) == 1, 'Third run with A type object is correct result');
    ok(test(B) == 2, 'Third run with B type object is correct result');
    ok(test(A.new) == 3, 'Third run with A instance is correct result');
    ok(test(B.new) == 4, 'Third run with B instance is correct result');
}

# Attribute fetch for guarding
{
    my class TestWithAttr {
        has $!attr;
        method new($attr) {
            my $self := nqp::create(self);
            nqp::bindattr($self, TestWithAttr, '$!attr', $attr);
            $self
        }
    }
    my $times-run := 0;
    nqp::speshreg('nqp', 'attr-type-and-definedness-counter', -> $obj {
        nqp::speshguardtype($obj, TestWithAttr);
        nqp::speshguardconcrete($obj);
        my $attr := nqp::speshguardgetattr($obj, TestWithAttr, '$!attr');
        nqp::speshguardtype($attr, $attr.WHAT);
        nqp::isconcrete($attr)
            ?? nqp::speshguardconcrete($attr)
            !! nqp::speshguardtypeobj($attr);
        ++$times-run
    });
    sub test($obj) {
        nqp::speshresolve('attr-type-and-definedness-counter', TestWithAttr.new($obj))
    }
    my class A { }
    my class B { }
    ok(test(A) == 1, 'First run with attr holding A type object is correct result');
    ok(test(A) == 1, 'Second run with attr holding A type object gets same result');
    ok(test(B) == 2, 'First run with attr holding B type object is correct result');
    ok(test(B) == 2, 'Second run with attr holding B type object gets same result');
    ok(test(A.new) == 3, 'First run with attr holding A instance is correct result');
    ok(test(A.new) == 3, 'Second run with attr holding A instance gets same result');
    ok(test(B.new) == 4, 'First run with attr holding B instance is correct result');
    ok(test(B.new) == 4, 'Second run with attr holding B instance gets same result');
    ok(test(A) == 1, 'Third run with A type attr holding object is correct result');
    ok(test(B) == 2, 'Third run with B type attr holding object is correct result');
    ok(test(A.new) == 3, 'Third run with A attr holding instance is correct result');
    ok(test(B.new) == 4, 'Third run with B attr holding instance is correct result');
}

# Guard for "any object except this one"
{
    my $do-not-want := NQPMu.new;
    my $times-run := 0;
    nqp::speshreg('nqp', 'not-the-unwanted', -> $obj {
        $times-run++;
        if nqp::eqaddr($obj, $do-not-want) {
            nqp::speshguardobj($obj);
            2
        }
        else {
            nqp::speshguardnotobj($obj, $do-not-want);
            4
        }
    });
    sub try-with-obj($obj) {
        nqp::speshresolve('not-the-unwanted', $obj);
    }
    my $total := 0;
    for NQPMu.new, NQPMu.new, NQPMu.new {
        $total := $total + try-with-obj($_);
    }
    ok($times-run > 0, 'Ran the spesh plugin with any object except guard');
    ok($times-run == 1, 'Ran the spesh registered block once per static resolve');
    ok($total == 12, 'Resolve gave expected result');

    # Check that the object guard is enforced.
    $times-run := 0;
    ok(try-with-obj($do-not-want) == 2, 'We get different value when any object except guard not met');
    ok($times-run == 1, 'Ran the spesh registered block again');
}

# Many calls, to exercise specialization, with an exact match guard that'd trigger
# deopt.
{
    my $times-run := 0;
    nqp::speshreg('nqp', 'assume-pure-spesh', -> $code {
        $times-run++;
        nqp::speshguardobj($code);
        $code()
    });
    my $a := 2;
    sub assumed-pure() { $a++ }
    my $total := 0;
    sub purify(&func) {
        nqp::speshresolve('assume-pure-spesh', &func);
    }
    sub hot-loop-a(&func) {
        my int $i := 0;
        while $i++ < 5_000_000 {
            $total := $total + purify(&func);
            $a++;
        }
    }
    hot-loop-a(&assumed-pure);
    ok($times-run == 1, 'Only ran the plugin once in hot code');
    ok($total == 10_000_000, 'Correct result from hot code');

    $a := 3;
    $times-run := 0;
    sub another() { $a }
    ok(purify(&another) == 3, 'Correct result when we trigger deopt');
    ok($times-run == 1, 'Ran the plugin another time if we had to deopt due to guard failure');
}

# Deopt by type guard.
{
    my $times-run := 0;
    nqp::speshreg('nqp', 'type-name-spesh', -> $obj {
        $times-run++;
        nqp::speshguardtype($obj, $obj.WHAT);
        $obj.HOW.name($obj)
    });
    my class AAA { }
    my @obj := [AAA];
    sub name() {
        nqp::speshresolve('type-name-spesh', nqp::atpos(@obj, 0));
    }
    sub hot-loop() {
        my int $i := 0;
        my $name := '';
        while $i++ < 1_000_000 {
            $name := $name ~ name();
        }
        return $name;
    }
    my $result := hot-loop();
    ok($times-run == 1, 'Only ran the type-based plugin once in hot code');
    ok($result eq nqp::x('AAA', 1_000_000), 'Correct result from hot code');

    $times-run := 0;
    my class BBB { }
    @obj[0] := BBB;
    ok(name() eq 'BBB', 'Correct result when we trigger type deopt');
    ok($times-run == 1, 'Ran the plugin another time if we had to deopt due to type guard failure');
}

# Deopt by concrete guard.
{
    my $times-run := 0;
    nqp::speshreg('nqp', 'concrete-spesh', -> $obj {
        $times-run++;
        nqp::isconcrete($obj) || nqp::die("Must have a concrete object");
        nqp::speshguardconcrete($obj);
        2
    });
    my class AAA { }
    my @obj := [AAA.new];
    sub conc() {
        nqp::speshresolve('concrete-spesh', nqp::atpos(@obj, 0));
    }
    sub hot-loop() {
        my int $i := 0;
        my $conc := 0;
        while $i++ < 1_000_000 {
            $conc := $conc + conc();
        }
        return $conc;
    }
    my $result := hot-loop();
    ok($times-run == 1, 'Only ran the concrete-based plugin once in hot code');
    ok($result == 2_000_000, 'Correct result from hot code');

    $times-run := 0;
    @obj[0] := AAA;
    my $msg := '';
    try { conc(); CATCH { $msg := nqp::getmessage($_) } }
    ok($msg eq 'Must have a concrete object', 'Correct result when we trigger concrete deopt');
    ok($times-run == 1, 'Ran the plugin another time if we had to deopt due to concrete guard failure');
}

# Deopt by type object.
{
    my $times-run := 0;
    nqp::speshreg('nqp', 'typeobj-spesh', -> $obj {
        $times-run++;
        nqp::isconcrete($obj) && nqp::die("Must have a type object");
        nqp::speshguardtypeobj($obj);
        2
    });
    my class AAA { }
    my @obj := [AAA];
    sub typeobj() {
        nqp::speshresolve('typeobj-spesh', nqp::atpos(@obj, 0));
    }
    sub hot-loop() {
        my int $i := 0;
        my $typeobj := 0;
        while $i++ < 1_000_000 {
            $typeobj := $typeobj + typeobj();
        }
        return $typeobj;
    }
    my $result := hot-loop();
    ok($times-run == 1, 'Only ran the type-object-based plugin once in hot code');
    ok($result == 2_000_000, 'Correct result from hot code');

    $times-run := 0;
    @obj[0] := AAA.new;
    my $msg := '';
    try { typeobj(); CATCH { $msg := nqp::getmessage($_) } }
    ok($msg eq 'Must have a type object', 'Correct result when we trigger type object deopt');
    ok($times-run == 1, 'Ran the plugin another time if we had to deopt due to type object guard failure');
}

# Deopt by attribute guard.
{
    my class TestWithAttr {
        has $!attr;
        method new($attr) {
            my $self := nqp::create(self);
            nqp::bindattr($self, TestWithAttr, '$!attr', $attr);
            $self
        }
    }
    my $times-run := 0;
    nqp::speshreg('nqp', 'attr-type-and-definedness-counter-spesh', -> $obj {
        nqp::speshguardtype($obj, TestWithAttr);
        nqp::speshguardconcrete($obj);
        my $attr := nqp::speshguardgetattr($obj, TestWithAttr, '$!attr');
        nqp::speshguardtype($attr, $attr.WHAT);
        nqp::isconcrete($attr)
            ?? nqp::speshguardconcrete($attr)
            !! nqp::speshguardtypeobj($attr);
        ++$times-run
    });
    my @obj;
    sub test() {
        nqp::speshresolve('attr-type-and-definedness-counter-spesh',
            TestWithAttr.new(nqp::atpos(@obj, 0)))
    }

    my class A { }
    sub hot-loop() {
        my int $i := 0;
        my int $total := 0;
        while $i++ < 1_000_000 {
            $total := $total + test();
        }
        return $total;
    }
    @obj[0] := A;
    my $result := hot-loop();
    ok($times-run == 1, 'Only ran the attribute type-based plugin once in hot code');
    ok($result == 1_000_000, 'Correct result from hot code');

    my class B { }
    @obj[0] := B;
    ok(test() == 2, 'Correct result when we trigger attr type deopt');
    ok($times-run == 2,
        'Ran the plugin another time if we had to deopt due to attr type guard failure');
}

# Deopt for "any object except this one"
{
    my $do-not-want := NQPMu.new;
    my $times-run := 0;
    nqp::speshreg('nqp', 'not-the-unwanted-spesh', -> $obj {
        $times-run++;
        if nqp::eqaddr($obj, $do-not-want) {
            nqp::speshguardobj($obj);
            2
        }
        else {
            nqp::speshguardnotobj($obj, $do-not-want);
            4
        }
    });
    sub try-with-obj($obj) {
        nqp::speshresolve('not-the-unwanted-spesh', $obj);
    }
    my int $i := 0;
    my int $total := 0;
    while $i++ < 1_000_000 {
        $total := $total + try-with-obj(NQPMu.new);
    }
    ok($times-run == 1, 'Ran the spesh plugin with not object guard one time even when hot');
    ok($total == 4_000_000, 'Correct result from the plugin every time');

    # Check that it will deopt OK.
    $times-run := 0;
    ok(try-with-obj($do-not-want) == 2, 'We did deopt when expected');
    ok($times-run == 1, 'Ran the spesh registered block again to recover from deopt');
}

# Recursive spesh plugin setup
{
    nqp::speshreg('nqp', 'rec-a', -> $code {
        $code()
    });
    nqp::speshreg('nqp', 'rec-b', -> {
        42
    });
    my $outcome := nqp::speshresolve('rec-a', -> {
        nqp::speshresolve('rec-b')
    });
    ok($outcome == 42, 'Recursive speshresolve calls work out');
}
