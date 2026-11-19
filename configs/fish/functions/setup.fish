function setup --description 'Open rice-settings (builds it first if missing; setup --build rebuilds)'
    set -l app "$HOME/Applications/rice-settings.app"
    if test "$argv[1]" = "--build"; or not test -d "$app"
        sh "$HOME/bin/rice-settings/build.sh"; or return 1
    end
    open "$app"
end
