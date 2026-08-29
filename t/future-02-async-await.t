use v5.36;
use strict;
use warnings;
use Test::More;

use Linux::Event;

async sub increment ($source) {
    my $value = await $source;
    return $value + 1;
}

async sub immediate () {
    return 7;
}

my $source = Linux::Event::Future->new;
my $result = increment($source);
isa_ok($result, 'Linux::Event::Future',
    'use Linux::Event selects the native Future class');
ok(!$result->is_ready, 'async sub suspends on native Future');
$source->done(41);
ok($result->is_ready, 'native completion resumes async sub');
is($result->get, 42, 'await result crosses the native contract');

my $immediate = immediate();
isa_ok($immediate, 'Linux::Event::Future',
    'immediate async result also uses the native Future class');
is($immediate->get, 7, 'immediate async result is available');

my $top_level = await Linux::Event::Future->AWAIT_NEW_DONE('ready');
is($top_level, 'ready', 'top-level await works without an explicit Loop');

done_testing;
