on 'configure' => sub {
    requires "ExtUtils::MakeMaker" => "0";
    requires "Alien::Build" => "0";
    requires "File::ShareDir::Install" => "0";
    requires "Sort::Versions" => "0";
};

on 'runtime' => sub {
    requires "URI::Escape" => "5.09";
    requires "HTML::Template" => "2.97";
    requires "File::ShareDir" => "0";
};

on 'test' => sub {
    requires "Test::More" => "0";
};
