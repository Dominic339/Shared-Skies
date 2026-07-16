package skies;

import com.onthegomap.planetiler.FeatureCollector;
import com.onthegomap.planetiler.Profile;
import com.onthegomap.planetiler.reader.SourceFeature;

/**
 * Minimal profile: only what Shared Skies actually needs for the first
 * rendering proof -- roads and water. Not the full generic OpenMapTiles
 * basemap schema; layers get added here as the Godot renderer proves it
 * needs them (land use / habitat tags next).
 */
public class SharedSkiesProfile implements Profile {

  @Override
  public void processFeature(SourceFeature sourceFeature, FeatureCollector features) {
    if (sourceFeature.canBeLine() && sourceFeature.hasTag("highway")) {
      features.line("roads")
          .setAttr("class", sourceFeature.getTag("highway"))
          .setAttr("name", sourceFeature.getTag("name"))
          .setMinZoom(9);
    }

    if (sourceFeature.hasTag("natural", "water") || sourceFeature.hasTag("waterway")) {
      if (sourceFeature.canBePolygon()) {
        features.polygon("water").setMinZoom(6);
      } else if (sourceFeature.canBeLine()) {
        features.line("water").setMinZoom(9);
      }
    }
  }

  @Override
  public String name() {
    return "Shared Skies";
  }
}
