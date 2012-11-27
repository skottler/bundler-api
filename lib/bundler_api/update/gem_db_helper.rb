require_relative '../../bundler_api'
require_relative '../metriks'

class BundlerApi::GemDBHelper
  def initialize(db, gem_cache, mutex)
    @db        = db
    @gem_cache = gem_cache
    @mutex     = mutex
  end

  def exists?(payload)
    key = payload.full_name

    if @mutex
      @mutex.synchronize do
        return @@gem_cache[key] if @gem_cache[key]
      end
    end

    timer   = Metriks.timer('job.gem_exists').time
    dataset = @db[<<-SQL, payload.name, payload.version.version, payload.platform]
    SELECT rubygems.id AS rubygem_id, versions.id AS version_id
    FROM rubygems, versions
    WHERE rubygems.id = versions.rubygem_id
      AND rubygems.name = ?
      AND versions.number = ?
      AND versions.platform = ?
      AND versions.indexed = true
    SQL

    result = dataset.first

    if @mutex
      @mutex.synchronize do
        @gem_cache[key] = result if result
      end
    end

    result
  ensure
    timer.stop if timer
  end

  def find_or_insert_rubygem(spec)
    insert     = nil
    rubygem_id = nil
    rubygem    = @db[:rubygems].filter(name: spec.name.to_s).select(:id).first

    if rubygem
      insert     = false
      rubygem_id = rubygem[:id]
    else
      insert     = true
      rubygem_id = @db[:rubygems].insert(
        name:       spec.name,
        created_at: Time.now,
        updated_at: Time.now,
        downloads:  0
      )
    end

    [insert, rubygem_id]
  end

  def find_or_insert_version(spec, rubygem_id, platform = 'ruby', indexed = nil)
    insert     = nil
    version_id = nil
    version    = @db[:versions].filter(
      rubygem_id: rubygem_id,
      number:     spec.version.version,
      platform:   platform
    ).select(:id, :indexed).first

    if version
      insert     = false
      version_id = version[:id]
      @db[:versions].where(id: version_id).update(indexed: indexed) if !indexed.nil? && version[:indexed] != indexed
    else
      insert     = true
      indexed    = true if indexed.nil?
      version_id = @db[:versions].insert(
        authors:     spec.authors,
        description: spec.description,
        number:      spec.version.version,
        rubygem_id:  rubygem_id,
        updated_at:  Time.now,
        summary:     spec.summary,
        # rubygems.org actually uses the platform from the index and not from the spec
        platform:    platform,
        created_at:  Time.now,
        indexed:     indexed,
        prerelease:  spec.version.prerelease?,
        latest:      true,
        full_name:   spec.full_name,
        # same setting as rubygems.org
        built_at:    spec.date
      )
    end

    [insert, version_id]
  end

  def insert_dependencies(spec, version_id)
    deps_added = []

    spec.dependencies.each do |dep|
      rubygem_name = nil
      requirement  = nil
      scope        = nil

      if dep.is_a?(Gem::Dependency)
        rubygem_name = dep.name.to_s
        requirement   = dep.requirement.to_s
        scope        = dep.type.to_s
      else
        rubygem_name, requirement = dep
        # assume runtime for legacy deps
        scope                     = "runtime"
      end

      dep_rubygem = @db[:rubygems].filter(name: rubygem_name).select(:id).first
      if dep_rubygem
        dep = @db[:dependencies].filter(requirements: requirement,
                                        rubygem_id:   dep_rubygem[:id],
                                        version_id:   version_id).first
        unless dep
          deps_added << "#{requirement} #{rubygem_name}"
          @db[:dependencies].insert(
            requirements: requirement,
            created_at:   Time.now,
            updated_at:   Time.now,
            rubygem_id:   dep_rubygem[:id],
            version_id:   version_id,
            scope:        scope
          )
        end
      end
    end

    deps_added
  end
end
