use warnings;
use strict;
use lib qw(lib);
use Plack::App::File;
use Plack::Middleware::SSI;
use Plack::Test;
use Plack::Builder;
use Test::More;

plan skip_all => 'no test files' unless -d 't/file';
plan tests => 29;

my $app = Plack::App::File->new(root => 't/file')->to_app;
my $SSI = 'Plack::Middleware::SSI';
my $TIME_RE = qr{\w+, \d+-\w+-\d+ [\d:]+};
my($res, $vars);

{
    open my $FH, '<', 't/file/readline.txt';
    my $buf = '';
    ok(Plack::Middleware::SSI::__readline(\$buf, $FH), '__readline() return true');
    is($buf, "first line\n", '__readline return one line');

    Plack::Middleware::SSI::__readline(\$buf, $FH); # second line...
    ok(!Plack::Middleware::SSI::__readline(\$buf, $FH), '__readline() return false after second line');
    is(length($buf), 23, 'all data is read');
}

{
    is(
        Plack::Middleware::SSI::__ANON__->__eval_condition('$foo', { foo => 123 }),
        123,
        'eval foo to 123'
    );

    no strict 'refs';
    is(${"Plack::Middleware::SSI::__ANON__::foo"}, 123, 'foo variable is part of __ANON__ package');
    Plack::Middleware::SSI::__ANON__->__eval_condition('$bar', { bar => 123 }),
    is(${"Plack::Middleware::SSI::__ANON__::foo"}, undef, 'foo variable is removed from __ANON__ package');
}

{
    no warnings;
    local *Plack::Middleware::SSI::app = sub { $app };

    $vars = vars();
    $res = $SSI->_parse_ssi_chunk($vars, ssi_str('invalid expression'));
    is($res, 'BEFORE[an error occurred while processing this directive]', 'SSI invalid expression: return comment');
    is($SSI->_parse_ssi_chunk($vars), '12345', 'got 12345 at end');

    $res = $SSI->_parse_ssi_chunk($vars, ssi_str('set var="foo" value="123"'));
    is($res, 'BEFORE', 'SSI set: will not result in any value');
    is($vars->{'foo'}, 123, 'SSI set: variable foo was found in expression');

    $res = $SSI->_parse_ssi_chunk({ foo => 123 }, ssi_str('echo var="foo"'));
    is($res, 'BEFORE123', 'SSI echo: return 123');

    $res = $SSI->_parse_ssi_chunk({}, ssi_str('echo var="foo"'));
    is($res, 'BEFORE', 'SSI echo: return empty string');

    $res = $SSI->_parse_ssi_chunk({}, ssi_str('fsize file="t/file/readline.txt"'));
    is($res, 'BEFORE23', 'SSI fsize: return 23');

    $res = $SSI->_parse_ssi_chunk({}, ssi_str('flastmod file="t/file/readline.txt"'));
    like($res, qr"^BEFORE$TIME_RE \w+$", 'SSI flastmod: return time string');

    $res = $SSI->_parse_ssi_chunk({}, ssi_str('include virtual="readline.txt"'));
    is($res, "BEFOREfirst line\nsecond line\n", 'SSI include: return readline.txt');

    $vars = vars();
    $res = $SSI->_parse_ssi_chunk($vars, if_elif_else()) .$SSI->_parse_ssi_chunk($vars);
    is($res, "\nELSE\nafter\n", 'SSI if/elif/else: ELSE');

    $vars = vars(B => 2);
    $res = $SSI->_parse_ssi_chunk($vars, if_elif_else()) .$SSI->_parse_ssi_chunk($vars);
    is($res, "\nELIF\nafter\n", 'SSI if/elif/else: ELIF');

    $vars = vars(A => 1);
    $res = $SSI->_parse_ssi_chunk($vars, if_elif_else()) .$SSI->_parse_ssi_chunk($vars);
    is($res, "\nIF\nafter\n", 'SSI if/elif/else: IF');
}

SKIP: {
    skip 'cannot execute "ls"', 1 if system 'ls >/dev/null';
    $res = $SSI->_parse_ssi_chunk({}, ssi_str('exec cmd="ls"'));
    like($res, qr{\w}, 'SSI cmd: return directory list');
}

SKIP: {
    my $ssi_app = builder { enable 'SSI'; $app };

    test_psgi app => $ssi_app, client => sub {
        my $cb = shift;
        my $res = $cb->(HTTP::Request->new(GET => 'http://localhost/index.html'));
        my $content = $res->content;

        is($res->code, 200, '..and code 200') or skip 'invalid response', 9;
        like($res->header('Content-Type'), qr{^text/html}, '..and with Content-Type text/html');

        TODO: {
            local $TODO = 'Content-Length is missing';
            is($res->header('Content-Length'), 12345, '..and with Content-Length');
        }

        like($content, qr{^<!DOCTYPE HTML}, 'parsed result contain beginning...');
        like($content, qr{</html>$}, '..and end of html file');
        like($content, qr{DOCUMENT_NAME=index.html}, 'index.html contains DOCUMENT_NAME');
        like($content, qr{DATE_GMT=$TIME_RE GMT}, 'index.html contains DATE_GMT');
        like($content, qr{DATE_LOCAL=$TIME_RE \w+}, 'index.html contains DATE_LOCAL');
        like($content, qr{LAST_MODIFIED=$TIME_RE \w+}, 'index.html contains LAST_MODIFIED');
    };
}

sub ssi_str {
    return 'BEFORE<!--#' .shift(@_) .' -->12345';
}

sub if_elif_else {
    <<'IF_ELIF_ELSE';
<!--#if expr="${A}" -->
IF
<!--#elif expr="${B}" -->
ELIF
<!--#else -->
ELSE
<!--#endif -->after
IF_ELIF_ELSE
}

sub vars {
    my $buf = '';
    return {
        __________BUF__________ => \$buf,
        @_,
    };
}
