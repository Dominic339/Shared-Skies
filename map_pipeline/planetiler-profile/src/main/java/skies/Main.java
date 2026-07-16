package skies;

import com.onthegomap.planetiler.Planetiler;

public class Main {
  public static void main(String[] args) throws Exception {
    Planetiler.create(com.onthegomap.planetiler.config.Arguments.fromArgs(args))
        .setProfile(new SharedSkiesProfile())
        .addOsmSource("osm", java.nio.file.Path.of(args.length > 0 ? args[0] : "new-hampshire.osm.pbf"))
        .overwriteOutput(java.nio.file.Path.of("nashua.mbtiles"))
        .run();
  }
}
