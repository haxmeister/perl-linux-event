use v5.36;
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);

my $command = join ' ',
    map { quotemeta($_) }
    $^X,
    '-Mblib',
    'bench/run-future-recv-microbench.pl',
    '--messages', '200',
    '--payload-size', '8',
    '--repeat', '1',
    '--json';
my $output = `$command`;
is($?, 0, 'Future receive benchmark exits successfully');

my $result = eval { decode_json($output) };
ok($result, 'Future receive benchmark emits JSON');
is($result->{messages}, 200, 'benchmark records message count');
for my $kind (qw(callback future)) {
    ok($result->{cases}{$kind}{seconds} > 0,
        "$kind benchmark duration is positive");
    ok($result->{cases}{$kind}{messages_per_second} > 0,
        "$kind benchmark rate is positive");
}
ok($result->{future_to_callback_rate} > 0,
    'benchmark reports a positive comparison ratio');

done_testing;
