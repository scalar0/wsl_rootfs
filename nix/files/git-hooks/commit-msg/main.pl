#!/usr/bin/env perl
use strict;
use warnings;

use constant ALLOWED_TYPES => {
    feat     => 1,
    fix      => 1,
    refactor => 1,
    fmt      => 1,
    test     => 1,
    docs     => 1,
    build    => 1,
    chore    => 1,
};

my @AUTO_BYPASS_PREFIXES = ("Merge ", "Revert ", "fixup! ", "squash! ");

sub usage_error {
    print STDERR "commit-msg: message file not provided or does not exist\n";
    exit 1;
}

sub read_message {
    my ($path) = @_;

    open my $fh, "<:encoding(UTF-8)", $path or usage_error();
    local $/;
    my $raw = <$fh>;
    close $fh;

    $raw =~ s/\r\n?/\n/g;

    my @lines;
    for my $line (split /\n/, $raw, -1) {
        next if $line =~ /^[ \t]*#/;
        next if $line =~ /^\$/;
        next if $line =~ /^\[\$/;
        push @lines, $line;
    }

    my $sanitized = join "\n", @lines;
    $sanitized .= "\n" unless $sanitized =~ /\n\z/;

    open my $out, ">:encoding(UTF-8)", $path or die "commit-msg: cannot rewrite $path: $!\n";
    print {$out} $sanitized;
    close $out;

    return @lines;
}

sub first_nonblank_line {
    my (@lines) = @_;

    for my $idx (0 .. $#lines) {
        return ($lines[$idx], $idx) if $lines[$idx] =~ /\S/;
    }

    return ("", -1);
}

sub collect_footers {
    my (@lines) = @_;

    my $first_footer_idx = scalar @lines;
    for (my $idx = $#lines; $idx >= 0; $idx--) {
        my $line = $lines[$idx];
        next unless $line =~ /\S/;
        if ($line =~ /^(?:BREAKING CHANGE|[A-Za-z-]+):\s/) {
            $first_footer_idx = $idx;
            next;
        }
        last;
    }

    my @footers;
    for my $idx ($first_footer_idx .. $#lines) {
        push @footers, $lines[$idx] if defined $lines[$idx] && $lines[$idx] =~ /\S/;
    }

    return ($first_footer_idx, @footers);
}

sub validate_header {
    my ($header, $reasons) = @_;

    if ($header !~ /^([a-z]+)(?:\(([^)]+)\))?(!)?:\s*(.+)$/) {
        push @{$reasons}, "line 1: header must match '<type>(<scope>)!: <subject>'";
        push @{$reasons}, "line 1: header is missing ': ' before the subject" if $header !~ /:\s/;
        push @{$reasons}, "line 1: header type must be lowercase" if $header =~ /^[A-Z]/;
        return ("", "", "", "");
    }

    my ($type, $scope, $bang, $subject) = ($1, $2 // "", $3 // "", $4);

    push @{$reasons}, "line 1: invalid type '$type'" unless ALLOWED_TYPES->{$type};
    push @{$reasons}, "line 1: scope '$scope' must match ^[A-Za-z0-9/-]+\$"
        if $scope ne "" && $scope !~ /^[A-Za-z0-9\/-]+\z/;

    my $subject_len = length $subject;
    push @{$reasons}, "line 1: subject must be 1-50 chars (got $subject_len)"
        if $subject_len < 1 || $subject_len > 50;
    push @{$reasons}, "line 1: subject must not end with a period" if $subject =~ /\.\z/;
    push @{$reasons}, "line 1: subject must start with a lowercase letter" if $subject !~ /^[a-z]/;
    push @{$reasons}, "line 1: subject contains invalid characters; allowed: [A-Za-z0-9 -_/():,#+]"
        if $subject !~ /^[A-Za-z0-9 \-_\x2f():,#+]*\z/;
    push @{$reasons}, "line 1: subject contains invalid characters; '!' is not allowed"
        if index($subject, "!") >= 0;

    return ($type, $scope, $bang, $subject);
}

sub validate_body {
    my ($lines, $header_idx, $first_footer_idx, $reasons) = @_;

    for my $idx (($header_idx + 1) .. ($first_footer_idx - 1)) {
        next unless defined $lines->[$idx];
        next unless $lines->[$idx] =~ /\S/;
        my $len = length $lines->[$idx];
        push @{$reasons}, "line " . ($idx + 1) . ": body exceeds 72 chars (got $len)"
            if $len > 72;
    }
}

sub validate_commit_message {
    my ($path) = @_;
    my @lines = read_message($path);
    my @reasons;

    my ($header, $header_idx) = first_nonblank_line(@lines);
    if ($header_idx < 0) {
        push @reasons, "empty commit message";
        return @reasons;
    }

    for my $prefix (@AUTO_BYPASS_PREFIXES) {
        return () if index($header, $prefix) == 0;
    }

    my $text = join "\n", @lines;
    push @reasons, "commit message contains forbidden internal markers"
        if $text =~ /\s*-+\s+IGNORE\s*-+/m;
    push @reasons, "commit message appears to contain a raw diff; remove patch content"
        if $text =~ /^(?:diff --git |\+\+\+ |--- |@@ )/m;

    my ($first_footer_idx, @footers) = collect_footers(@lines);
    my (undef, undef, $bang, undef) = validate_header($header, \@reasons);

    if ($bang) {
        my $has_breaking_footer = 0;
        for my $footer (@footers) {
            if (index($footer, "BREAKING CHANGE: ") == 0) {
                $has_breaking_footer = 1;
                last;
            }
        }
        push @reasons, "line 1: '!' requires a 'BREAKING CHANGE:' footer explaining the change"
            unless $has_breaking_footer;
    }

    validate_body(\@lines, $header_idx, $first_footer_idx, \@reasons);
    return @reasons;
}

sub print_error_summary {
    my (@reasons) = @_;

    print STDERR "commit message validation failed:\n";
    print STDERR "  - $_\n" for @reasons;
    print STDERR "\n";
    print STDERR "Expected header: <type>(<scope>)!: <subject>\n";
    print STDERR "Where:\n";
    print STDERR "  - type one of: feat|fix|refactor|fmt|test|docs|build|chore\n";
    print STDERR "  - scope (optional) matches ^[A-Za-z0-9/-]+\$\n";
    print STDERR "  - ! (optional) indicates breaking change and REQUIRES a 'BREAKING CHANGE:' footer\n";
    print STDERR "  - subject: 1-50 chars, lowercase start, allowed: [A-Za-z0-9 \\ -_/():,#+], no trailing .\n";
    print STDERR "\n";
    print STDERR "Body (optional): lines wrapped to <= 72 chars.\n";
    print STDERR "Footers (optional): one trailer per line, e.g. 'BREAKING CHANGE: ...'\n";
    print STDERR "\n";
    print STDERR "Examples:\n";
    print STDERR "  feat(cli): add terse output flag\n";
    print STDERR "  fix: handle empty input without panic\n";
}

my $msg_path = shift @ARGV;
usage_error() unless defined $msg_path && -e $msg_path;

my @reasons = validate_commit_message($msg_path);
if (@reasons) {
    print_error_summary(@reasons);
    exit 1;
}

exit 0;
