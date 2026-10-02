using Landis.Utilities;
using Landis.Core;
using log4net;
using System;
using System.Collections;
using System.Reflection;
using Landis.SpatialModeling;

using Landis.Library.UniversalCohorts;

namespace Landis.Library.Succession
{
    public static class Reproduction
    {
        /// <summary>
        /// Various delegates associated with reproduction.
        /// </summary>
        public static class Delegates
        {
            /// <summary>
            /// A method to add new young cohort for a particular species at a
            /// site.
            /// </summary>
            public delegate void AddNewCohort(ISpecies species, ActiveSite site, string reproductionType, double propBiomass = 1.0);

            //- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

            /// <summary>
            /// A method to determine if there is sufficient light at a site for
            /// a species to reproduce.
            /// </summary>
            public delegate bool SufficientResources(ISpecies   species, ActiveSite site);

            /// <summary>
            /// A method to determine if a species can establish given the establishment probabilities.
            /// </summary>
            public delegate bool Establish(ISpecies species, ActiveSite site);

            /// <summary>
            /// A method to determine if a species can be planted given the establishment probabilities.
            /// </summary>
            public delegate bool PlantingEstablish(ISpecies species, ActiveSite site);

            /// <summary>
            /// A method for determining whether a mature cohort is present at a site for a given species.
            /// </summary>
            public delegate bool MaturePresent(ISpecies species, ActiveSite site);

            /// <summary>
            /// A method for determining the establishment probability at a site for a given species.
            /// </summary>
            public delegate double EstablishmentProbability(ISpecies species, ActiveSite site);

            /// <summary>
            /// A method for determining the mature biomass at a site for a given species.
            /// </summary>
            public delegate double MatureBiomass(ISpecies species, ActiveSite site);

            /// <summary>
            /// A method for determining the active biomass at a site for a given species.
            /// </summary>
            public delegate double ActiveBiomass(ISpecies species, ActiveSite site);

            /// <summary>
            /// A method for determining the foliage mass at a site for a given species.
            /// </summary>
            public delegate double MatureFolMass(ISpecies species, ActiveSite site);

            /// <summary>
            /// A method for determining the seeds produced at a site for a given species using the Density Succession method.
            /// </summary>
            public delegate int DensitySeeds(ISpecies species, ActiveSite site);


        }

        //---------------------------------------------------------------------

        private static Seeding seeding;

        private static ISpeciesDataset speciesDataset;
        private static ISiteVar<BitArray> resprout;
        private static ISiteVar<BitArray> serotiny;
        //private static ISiteVar<BitArray> planting;
        private static ISiteVar<bool> noEstablish;
        private static IPlanting planting;

        // We must synchronize access to each site's cohort list: while one
        // worker thread adds/removes cohorts at a site, another thread may be
        // reading (iterating) that same site's cohort list during seed
        // dispersal, which would otherwise crash with a "collection was
        // modified during enumeration" error.
        //
        // Instead of one lock object per active site (about 128 MB of lock
        // objects on a 4-million-cell landscape, spent even when running with a
        // single thread), we use a small fixed set of "striped" locks. Each
        // site maps to a stripe via "data index % SiteLockCount" (see
        // GetSiteLock below), so memory stays O(1).
        //
        // SiteLockCount only needs to be comfortably larger than the number of
        // worker threads (ThreadCount). Collisions are then rare and harmless.
        private const int SiteLockCount = 1024;

        private static readonly object[] siteLocks = CreateSiteLocks();

        private static Delegates.AddNewCohort addNewCohort;
        private static Delegates.SufficientResources lightMethod = ReproductionDefaults.SufficientResources;
        private static Delegates.Establish estbMethod = ReproductionDefaults.Establish;
        private static Delegates.PlantingEstablish plantEstbMethod = ReproductionDefaults.PlantingEstablish;
        private static Delegates.MaturePresent isMaturePresentMethod;
        public static Delegates.EstablishmentProbability estabProb = ReproductionDefaults.EstablishmentProbability;
        public static Delegates.MatureBiomass matureBiomass = ReproductionDefaults.MatureBiomass;
        public static Delegates.ActiveBiomass activeBiomass = ReproductionDefaults.ActiveBiomass;
        public static Delegates.MatureFolMass folMass = ReproductionDefaults.MatureFolMass;
        public static Delegates.DensitySeeds densitySeeds = ReproductionDefaults.DensitySeeds;

        private static readonly ILog log = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        private static readonly bool isDebugEnabled = log.IsDebugEnabled;

        //---------------------------------------------------------------------

        /// <summary>
        /// The method that this class uses to add new young cohort for a
        /// particular species at a site.
        /// </summary>
        public static Delegates.AddNewCohort AddNewCohort
        {
            get {
                return addNewCohort;
            }
            set
            {
                Require.ArgumentNotNull(value);
                addNewCohort = value;
            }
        }

        //---------------------------------------------------------------------

        /// <summary>
        /// The method that this class uses to determine if there is sufficient
        /// light at a site for a species to reproduce.
        /// </summary>
        public static Delegates.SufficientResources SufficientResources
        {
            get {
                return lightMethod;
            }

            set {
                Require.ArgumentNotNull(value);
                lightMethod = value;
            }
        }

        //---------------------------------------------------------------------

        public static Delegates.Establish Establish
        {
            get
            {
                return estbMethod;
            }

            set
            {
                Require.ArgumentNotNull(value);
                estbMethod = value;
            }
        }

        //---------------------------------------------------------------------

        public static Delegates.PlantingEstablish PlantingEstablish
        {
            get
            {
                return plantEstbMethod;
            }

            set
            {
                Require.ArgumentNotNull(value);
                plantEstbMethod = value;
            }
        }
        //---------------------------------------------------------------------

        public static Delegates.MaturePresent MaturePresent
        {
            get
            {
                return isMaturePresentMethod;
            }

            set
            {
                Require.ArgumentNotNull(value);
                isMaturePresentMethod = value;
            }
        }

        //---------------------------------------------------------------------

        public static Delegates.EstablishmentProbability EstablishmentProbability
        {
            get
            {
                return estabProb;
            }

            set
            {
                Require.ArgumentNotNull(value);
                estabProb = value;
            }
        }

        //---------------------------------------------------------------------
        public static Delegates.MatureBiomass MatureBiomass
        {
            get
            {
                return matureBiomass;
            }

            set
            {
                Require.ArgumentNotNull(value);
                matureBiomass = value;
            }
        }
        //---------------------------------------------------------------------
        public static Delegates.ActiveBiomass ActiveBiomass
        {
            get
            {
                return activeBiomass;
            }

            set
            {
                Require.ArgumentNotNull(value);
                activeBiomass = value;
            }
        }
        //---------------------------------------------------------------------
        public static Delegates.MatureFolMass MatureFolMass
        {
            get
            {
                return folMass;
            }

            set
            {
                Require.ArgumentNotNull(value);
                folMass = value;
            }
        }        
        //---------------------------------------------------------------------
        public static Delegates.DensitySeeds DensitySeeds
        {
            get
            {
                return densitySeeds;
            }

            set
            {
                Require.ArgumentNotNull(value);
                densitySeeds = value;
            }
        }
        //---------------------------------------------------------------------

        public static void Initialize(SeedingAlgorithm seedingAlgorithm)
        {

            seeding = new Seeding(seedingAlgorithm);

            speciesDataset = Model.Core.Species;
            int speciesCount = speciesDataset.Count;

            resprout = Model.Core.Landscape.NewSiteVar<BitArray>();
            serotiny = Model.Core.Landscape.NewSiteVar<BitArray>();
            noEstablish = Model.Core.Landscape.NewSiteVar<bool>();
            foreach (ActiveSite site in Model.Core.Landscape.ActiveSites) {
                resprout[site] = new BitArray(speciesCount);
                serotiny[site] = new BitArray(speciesCount);
            }

            noEstablish.ActiveSiteValues = false;
            planting = new Planting();

        }

        //---------------------------------------------------------------------

        /// <summary>
        /// Records a species that should be checked for resprouting during
        /// reproduction.
        /// </summary>
        /// <param name="cohort">
        /// The cohort whose death triggered the current call to this method.
        /// </param>
        /// <param name="site">
        /// The site where the cohort died.
        /// </param>
        /// <remarks>
        /// If the cohort's age is within the species' age range for
        /// resprouting, then the species will be have additional resprouting
        /// criteria (light, probability) checked during reproduction.
        /// </remarks>
        public static void CheckForResprouting(ICohort cohort, ActiveSite site)
        {
            ISpecies species = cohort.Species;
            if (species.MinSproutAge <= cohort.Data.Age && cohort.Data.Age <= species.MaxSproutAge)
                resprout[site].Set(species.Index, true);
        }

        //---------------------------------------------------------------------

        /// <summary>
        /// Records a species that should be checked for post-fire regeneration
        /// during reproduction.
        /// </summary>
        /// <param name="cohort">
        /// The cohort whose death triggered the current call to this method.
        /// </param>
        /// <param name="site">
        /// The site where the cohort died.
        /// </param>
        /// <remarks>
        /// If the cohort's species has resprouting as its post-fire
        /// regeneration, then the CheckForResprouting method is called with
        /// the cohort.  If the species has serotiny as its post-fire
        /// regeneration, then the species will be checked for on-site seeding
        /// during reproduction.
        /// </remarks>
        public static void CheckForPostFireRegen(ICohort cohort,
                                                 ActiveSite        site)
        {
            ISpecies species = cohort.Species;
            switch (species.PostFireRegeneration) {
                case PostFireRegeneration.Resprout:
                    CheckForResprouting(cohort, site);
                    break;

                case PostFireRegeneration.Serotiny:
                    if (cohort.Data.Age >= species.Maturity)
                        serotiny[site].Set(species.Index, true);
                    break;

                default:
                    //  Do nothing
                    break;
            }
        }

        //---------------------------------------------------------------------

        /// <summary>
        /// Schedules a list of species to be planted at a site.
        /// </summary>
        public static void ScheduleForPlanting(Planting.SpeciesList speciesToPlant,
                                               ActiveSite           site)
        {
            planting.Schedule(speciesToPlant, site);
        }

        //---------------------------------------------------------------------

        /// <summary>
        /// Schedules a list of species to be planted at a site.
        /// </summary>
        public static void PreventEstablishment(ActiveSite site)
        {
            noEstablish[site] = true;
        }
        //---------------------------------------------------------------------
        /// <summary>
        /// Re-enables establishment at a site for a list of species
        /// </summary>
        public static void EnableEstablishment(ActiveSite site)
        {
            noEstablish[site] = false;
        }
        //---------------------------------------------------------------------

        /// <summary>
        /// Returns the lock object that guards a site's cohort collection.
        ///
        /// IMPORTANT — DO NOT NEST THESE LOCKS.
        /// These locks are "striped": many different sites share the same lock
        /// object. That is fine as long as each lock is taken on its own and
        /// released before the next one is taken (which is how all the current
        /// code behaves).
        ///
        /// Never put a GetSiteLock(...) lock INSIDE another GetSiteLock(...)
        /// lock. If a future change ever modifies two sites' cohorts at once,
        /// take the two locks one after the other, not one inside the other.
        /// Nesting them can deadlock: the simulation then freezes silently with
        /// no error message, which is very hard to diagnose.
        /// </summary>
        internal static object GetSiteLock(ActiveSite site)
        {
            return siteLocks[(int)(site.DataIndex % SiteLockCount)];
        }

        /// <summary>
        /// Creates the fixed, striped set of lock objects.
        /// </summary>
        private static object[] CreateSiteLocks()
        {
            var locks = new object[SiteLockCount];
            for (int i = 0; i < locks.Length; i++)
                locks[i] = new object();
            return locks;
        }

        /// <summary>
        /// Does the appropriate forms of reproduction at a site.
        /// </summary>
        public static void Reproduce(ActiveSite site, ThreadSafeRandom randomGen = null)
        {
            if (noEstablish[site])
                return;

            object siteLock = GetSiteLock(site);

            bool plantingOccurred;
            lock (siteLock)
            {
                plantingOccurred = planting.TryAt(site);
            }

            bool sufficientLight;

            bool serotinyOccurred = false;
            if (!plantingOccurred)
            {
                for (int index = 0; index < speciesDataset.Count; ++index)
                {
                    if (serotiny[site].Get(index))
                    {
                        ISpecies species = speciesDataset[index];
                        sufficientLight = SufficientResources(species, site);
                        if (sufficientLight && Establish(species, site))
                        {
                            lock (siteLock)
                            {
                                AddNewCohort(species, site, "serotiny", 1.0);
                            }
                            serotinyOccurred = true;
                            if (isDebugEnabled)
                                log.DebugFormat("site {0}: {1} post-fire regenerated",
                                                site.Location, species.Name);
                        }
                        else
                        {
                            if (isDebugEnabled)
                                log.DebugFormat("site {0}: {1} post-fire regen failed: {2}",
                                                site.Location, species.Name,
                                                !sufficientLight ? "insufficient light"
                                                                  : "didn't establish");
                        }
                    }
                }
            }
            serotiny[site].SetAll(false);

            bool speciesResprouted = false;
            if (!serotinyOccurred)
            {
                for (int index = 0; index < speciesDataset.Count; ++index)
                {
                    if (resprout[site].Get(index))
                    {
                        ISpecies species = speciesDataset[index];
                        sufficientLight = SufficientResources(species, site);
                        if (sufficientLight &&
                                ((randomGen == null ? Model.Core.NextDouble() : randomGen.NextDouble()) < species.VegReprodProb))
                        {
                            lock (siteLock)
                            {
                                AddNewCohort(species, site, "resprout", 1.0);
                            }
                            speciesResprouted = true;
                            if (isDebugEnabled)
                                log.DebugFormat("site {0}: {1} resprouted",
                                                site.Location, species.Name);
                        }
                        else
                        {
                            if (isDebugEnabled)
                                log.DebugFormat("site {0}: {1} resprouting failed: {2}",
                                                site.Location, species.Name,
                                                !sufficientLight ? "insufficient light"
                                                                  : "random # >= probability");
                        }
                    }
                }
            }
            resprout[site].SetAll(false);

            planting.NotTriedAt(site);
            if (!plantingOccurred && !serotinyOccurred && !speciesResprouted)
                seeding.Do(site, randomGen);
        }


        //---------------------------------------------------------------------
    }
}
