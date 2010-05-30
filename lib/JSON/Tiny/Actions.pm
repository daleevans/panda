class JSON::Tiny::Actions;

method TOP($/) {
    make $/.hash.values.[0].ast;
};
method object($/) {
    say $<pairlist>.ast.hash.perl;
    make $<pairlist>.ast.hash ;
}

method pairlist($/) {
    if $<pair> {
        make $<pair>>>.ast;
    }
    else {
        make ();
    }
}

method pair($/) {
    make ( $<string>.ast => $<value>.ast );
}

method array($/) {
    if $<value> {
        make [$<value>>>.ast];
    } else {
        make [];
    }
}

method string($/) {
    my $s = '';
    for $0.chunks {
        if .key eq '~' {
            if .value eq '\\' { next }
            $s ~= .value;
        } else {
            $s ~= .value.ast;
        }
    }
    say "String: $s.perl()";
    make $s;
}
method value:sym<number>($/) { say "Number: $/"; make +$/}
method value:sym<string>($/) { make $<string>.ast }
method value:sym<true>($/)   { make Bool::True  }
method value:sym<false>($/)  { make Bool::False }
method value:sym<null>($/)   { make Any }
method value:sym<object>($/) { make $<object>.ast }
method value:sym<array>($/)  { make $<array>.ast }

method str($/)               { make ~$/ }

method str_escape($/) {
    if $<xdigit> {
        make chr(:16($<xdigit>.join));
    } else {
        given ~$/ {
            when '\\' { make '\\'; }
            when 'n'  { make "\n"; }
            when 't'  { make "\t"; }
            when 'f'  { make "\f"; }
            when 'r'  { make "\r"; }
        }
    }
}


# vim: ft=perl6
