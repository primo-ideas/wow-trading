use std::fmt;
use std::str::FromStr;

/// Battle.net regions served by `{region}.api.blizzard.com`. China uses other
/// hosts and is not supported.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Region {
    Us,
    Eu,
    Kr,
    Tw,
}

impl Region {
    pub const ALL: [Region; 4] = [Region::Us, Region::Eu, Region::Kr, Region::Tw];

    pub fn as_str(self) -> &'static str {
        match self {
            Region::Us => "us",
            Region::Eu => "eu",
            Region::Kr => "kr",
            Region::Tw => "tw",
        }
    }
}

impl fmt::Display for Region {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Which connected realms of a region to follow. Its commodity market is always followed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RealmSelection {
    CommoditiesOnly,
    All,
    Slugs(Vec<String>),
}

impl RealmSelection {
    fn merged_with(self, other: RealmSelection) -> RealmSelection {
        use RealmSelection::{All, CommoditiesOnly, Slugs};
        match (self, other) {
            (All, _) | (_, All) => All,
            (CommoditiesOnly, selection) | (selection, CommoditiesOnly) => selection,
            (Slugs(mut slugs), Slugs(more)) => {
                slugs.extend(more);
                Slugs(slugs)
            }
        }
    }
}

/// What to fetch.
///
/// Written as comma-separated entries: `eu` for a whole region, `eu/hyjal` for
/// one realm, `eu/commodities` for the commodity market alone. Empty means every
/// realm of every region.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scope(Vec<(Region, RealmSelection)>);

impl Scope {
    pub fn everything() -> Self {
        Self(
            Region::ALL
                .into_iter()
                .map(|region| (region, RealmSelection::All))
                .collect(),
        )
    }

    pub fn single(region: Region, selection: RealmSelection) -> Self {
        Self(vec![(region, selection)])
    }

    pub fn regions(&self) -> &[(Region, RealmSelection)] {
        &self.0
    }

    fn add(&mut self, region: Region, selection: RealmSelection) {
        match self.0.iter_mut().find(|(known, _)| *known == region) {
            Some((_, existing)) => {
                let current = std::mem::replace(existing, RealmSelection::CommoditiesOnly);
                *existing = current.merged_with(selection);
            }
            None => self.0.push((region, selection)),
        }
    }
}

const COMMODITIES_SLUG: &str = "commodities";

impl FromStr for Scope {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, String> {
        if value.trim().is_empty() {
            return Ok(Self::everything());
        }

        let mut scope = Self(Vec::new());
        for entry in value.split(',').map(str::trim).filter(|entry| !entry.is_empty()) {
            let entry = entry.to_lowercase();
            let (region, realm) = match entry.split_once('/') {
                Some((region, realm)) => (region, Some(realm)),
                None => (entry.as_str(), None),
            };
            let region = Region::ALL
                .into_iter()
                .find(|candidate| candidate.as_str() == region)
                .ok_or_else(|| {
                    format!("unknown region '{region}' in '{entry}': expected us, eu, kr or tw")
                })?;
            let selection = match realm {
                None => RealmSelection::All,
                Some("") => return Err(format!("missing realm after '/' in '{entry}'")),
                Some(COMMODITIES_SLUG) => RealmSelection::CommoditiesOnly,
                Some(slug) => RealmSelection::Slugs(vec![slug.to_owned()]),
            };
            scope.add(region, selection);
        }
        if scope.0.is_empty() {
            return Err(format!("no region or realm in '{value}'"));
        }
        Ok(scope)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use RealmSelection::{All, CommoditiesOnly, Slugs};

    fn parse(value: &str) -> Vec<(Region, RealmSelection)> {
        value.parse::<Scope>().unwrap().regions().to_vec()
    }

    #[test]
    fn empty_means_everything() {
        assert_eq!(parse(""), Scope::everything().regions());
        assert_eq!(parse("  "), Scope::everything().regions());
        assert_eq!(parse("").len(), 4);
        assert!(parse("").iter().all(|(_, selection)| *selection == All));
    }

    #[test]
    fn a_region_alone_means_all_its_realms() {
        assert_eq!(parse("eu"), [(Region::Eu, All)]);
    }

    #[test]
    fn a_realm_selects_it_within_its_region() {
        assert_eq!(
            parse("eu/hyjal"),
            [(Region::Eu, Slugs(vec!["hyjal".into()]))]
        );
    }

    #[test]
    fn commodities_can_be_selected_alone() {
        assert_eq!(parse("us/commodities"), [(Region::Us, CommoditiesOnly)]);
    }

    #[test]
    fn entries_of_a_region_are_merged() {
        assert_eq!(
            parse(" EU/Hyjal, eu/archimonde ,us,"),
            [
                (
                    Region::Eu,
                    Slugs(vec!["hyjal".into(), "archimonde".into()])
                ),
                (Region::Us, All)
            ]
        );
    }

    #[test]
    fn a_whole_region_wins_over_its_realms() {
        assert_eq!(parse("eu/hyjal,eu"), [(Region::Eu, All)]);
        assert_eq!(parse("eu,eu/hyjal"), [(Region::Eu, All)]);
    }

    #[test]
    fn a_realm_wins_over_commodities_only() {
        assert_eq!(
            parse("eu/commodities,eu/hyjal"),
            [(Region::Eu, Slugs(vec!["hyjal".into()]))]
        );
    }

    #[test]
    fn rejects_what_it_cannot_honor() {
        assert!(
            "mars/hyjal"
                .parse::<Scope>()
                .unwrap_err()
                .contains("unknown region 'mars'")
        );
        assert!(
            "eu/"
                .parse::<Scope>()
                .unwrap_err()
                .contains("missing realm")
        );
        assert!(",".parse::<Scope>().is_err());
    }
}
