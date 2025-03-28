on 'configure' => sub {
    requires "ExtUtils::MakeMaker" => "0";
    requires "Alien::Build" => "0";
    requires "File::ShareDir::Install" => "0";
    requires "Sort::Versions" => "0";
    requires "IO::Socket::SSL" => "1.56";
    requires "Net::SSLeay" => "1.49";
};

on 'runtime' => sub {
    requires "Encode" => "2.98";
    requires "URI::Escape" => "5.09";
    requires "HTML::Template" => "2.97";
    requires "File::ShareDir" => "0";
    requires "Feature::Compat::Try" => "0.05";
};

on 'test' => sub {
    requires "Test2::V0" => "0";
};

on 'develop' => sub {
    recommends "Test::CheckManifest" => "0.9";
    recommends "Test::Pod" => "1.22";
};
