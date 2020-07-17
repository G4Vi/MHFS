sub LoadMHFSModule {
            my ($name) = @_;
            if(!do $name) {
                say "MHFS module $name failed to load";
                return 0;
            } 
            return 1;
        }
        if(LoadMHFSModule('./mhfs-modules/ExampleModule.pm')) {
            print Dumper(ExampleModule->routes);
        }
        #die;
        