require File.join(File.dirname(File.expand_path(__FILE__)), "spec_helper")

describe "Model#save server use" do
  
  before(:each) do
    @c = Class.new(Sequel::Model(:items)) do
      columns :id, :x, :y
    end
    @c.db = MockDatabase.new
    db2 = @db2 = MockDatabase.new
    @c.class_eval do
      define_method(:after_save) do
        model.db = db2
        ds = model.dataset
        def ds.fetch_rows(sql)
          yield @db.execute(sql, @opts[:server])
        end
        @this = nil
      end
    end
  end

  it "should use the :default server if the model doesn't have one already specified" do
    @c.db.should_receive(:execute).with("INSERT INTO items (x) VALUES (1)").and_return(10)
    @db2.should_receive(:execute).with('SELECT * FROM items WHERE (id = 10) LIMIT 1', :default).and_return(:x=>1, :id=>10)
    @c.new(:x=>1).save
  end

  it "should use the model's server if the model has one already specified" do
    @c.dataset = @c.dataset.server(:blah)
    @c.db.should_receive(:execute).with("INSERT INTO items (x) VALUES (1)").and_return(10)
    @db2.should_receive(:execute).with('SELECT * FROM items WHERE (id = 10) LIMIT 1', :blah).and_return(:x=>1, :id=>10)
    @c.new(:x=>1).save
  end
end

describe "Model#save" do
  before do
    @c = Class.new(Sequel::Model(:items)) do
      columns :id, :x, :y
    end
    @c.dataset.meta_def(:insert){|h| super(h); 1}
    MODEL_DB.reset
  end
  
  it "should insert a record for a new model instance" do
    o = @c.new(:x => 1)
    o.save
    MODEL_DB.sqls.should == ["INSERT INTO items (x) VALUES (1)",
      "SELECT * FROM items WHERE (id = 1) LIMIT 1"]
  end

  it "should use dataset's insert_select method if present" do
    ds = @c.dataset = @c.dataset.clone
    def ds.insert_select(hash)
      execute("INSERT INTO items (y) VALUES (2)")
      {:y=>2}
    end
    o = @c.new(:x => 1)
    o.save
    
    o.values.should == {:y=>2}
    MODEL_DB.sqls.should == ["INSERT INTO items (y) VALUES (2)"]
  end

  it "should use value returned by insert as the primary key and refresh the object" do
    @c.dataset.meta_def(:insert){|h| super(h); 13}
    o = @c.new(:x => 11)
    o.save
    MODEL_DB.sqls.should == ["INSERT INTO items (x) VALUES (11)",
      "SELECT * FROM items WHERE (id = 13) LIMIT 1"]
  end

  it "should allow you to skip refreshing by overridding _save_refresh" do
    @c.dataset.meta_def(:insert){|h| super(h); 13}
    @c.send(:define_method, :_save_refresh){}
    @c.create(:x => 11)
    MODEL_DB.sqls.should == ["INSERT INTO items (x) VALUES (11)"]
  end

  it "should work correctly for inserting a record without a primary key" do
    @c.dataset.meta_def(:insert){|h| super(h); 13}
    @c.no_primary_key
    o = @c.new(:x => 11)
    o.save
    MODEL_DB.sqls.should == ["INSERT INTO items (x) VALUES (11)"]
  end

  it "should set the autoincrementing_primary_key value to the value returned by insert" do
    @c.dataset.meta_def(:insert){|h| super(h); 13}
    @c.unrestrict_primary_key
    @c.set_primary_key [:x, :y]
    o = @c.new(:x => 11)
    o.meta_def(:autoincrementing_primary_key){:y}
    o.save
    MODEL_DB.sqls.length.should == 2
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (11)"
    MODEL_DB.sqls.last.should =~ %r{SELECT \* FROM items WHERE \(\([xy] = 1[13]\) AND \([xy] = 1[13]\)\) LIMIT 1}
  end

  it "should update a record for an existing model instance" do
    o = @c.load(:id => 3, :x => 1)
    o.save
    MODEL_DB.sqls.should == ["UPDATE items SET x = 1 WHERE (id = 3)"]
  end
  
  it "should raise a NoExistingObject exception if the dataset update call doesn't return 1, unless require_modification is false" do
    o = @c.load(:id => 3, :x => 1)
    o.this.meta_def(:update){|*a| 0}
    proc{o.save}.should raise_error(Sequel::NoExistingObject)
    o.this.meta_def(:update){|*a| 2}
    proc{o.save}.should raise_error(Sequel::NoExistingObject)
    o.this.meta_def(:update){|*a| 1}
    proc{o.save}.should_not raise_error
    
    o.require_modification = false
    o.this.meta_def(:update){|*a| 0}
    proc{o.save}.should_not raise_error
    o.this.meta_def(:update){|*a| 2}
    proc{o.save}.should_not raise_error
  end
  
  it "should update only the given columns if given" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.save(:y)
    MODEL_DB.sqls.first.should == "UPDATE items SET y = NULL WHERE (id = 3)"
  end
  
  it "should mark saved columns as not changed" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o[:y] = 4
    o.changed_columns.should == [:y]
    o.save(:x)
    o.changed_columns.should == [:y]
    o.save(:y)
    o.changed_columns.should == []
  end
  
  it "should mark all columns as not changed if this is a new record" do
    o = @c.new(:x => 1, :y => nil)
    o.x = 4
    o.changed_columns.should == [:x]
    o.save
    o.changed_columns.should == []
  end
  
  it "should mark all columns as not changed if this is a new record and insert_select was used" do
    @c.dataset.meta_def(:insert_select){|h| h.merge(:id=>1)}
    o = @c.new(:x => 1, :y => nil)
    o.x = 4
    o.changed_columns.should == [:x]
    o.save
    o.changed_columns.should == []
  end

  it "should store previous value of @new in @was_new and as well as the hash used for updating in @columns_updated until after hooks finish running" do
    res = nil
    @c.send(:define_method, :after_save){ res = [@columns_updated, @was_new]}
    o = @c.new(:x => 1, :y => nil)
    o[:x] = 2
    o.save
    res.should == [nil, true]
    o.after_save
    res.should == [nil, nil]

    res = nil
    o = @c.load(:id => 23,:x => 1, :y => nil)
    o[:x] = 2
    o.save
    res.should == [{:x => 2, :y => nil}, nil]
    o.after_save
    res.should == [nil, nil]

    res = nil
    o = @c.load(:id => 23,:x => 2, :y => nil)
    o[:x] = 2
    o[:y] = 22
    o.save(:x)
    res.should == [{:x=>2},nil]
    o.after_save
    res.should == [nil, nil]
  end
  
  it "should use Model's use_transactions setting by default" do
    @c.use_transactions = true
    @c.load(:id => 3, :x => 1, :y => nil).save(:y)
    MODEL_DB.sqls.should == ["BEGIN", "UPDATE items SET y = NULL WHERE (id = 3)", "COMMIT"]
    MODEL_DB.reset
    @c.use_transactions = false
    @c.load(:id => 3, :x => 1, :y => nil).save(:y)
    MODEL_DB.sqls.should == ["UPDATE items SET y = NULL WHERE (id = 3)"]
    MODEL_DB.reset
  end

  it "should inherit Model's use_transactions setting" do
    @c.use_transactions = true
    Class.new(@c).load(:id => 3, :x => 1, :y => nil).save(:y)
    MODEL_DB.sqls.should == ["BEGIN", "UPDATE items SET y = NULL WHERE (id = 3)", "COMMIT"]
    MODEL_DB.reset
    @c.use_transactions = false
    Class.new(@c).load(:id => 3, :x => 1, :y => nil).save(:y)
    MODEL_DB.sqls.should == ["UPDATE items SET y = NULL WHERE (id = 3)"]
    MODEL_DB.reset
  end

  it "should use object's use_transactions setting" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.use_transactions = false
    @c.use_transactions = true
    o.save(:y)
    MODEL_DB.sqls.should == ["UPDATE items SET y = NULL WHERE (id = 3)"]
    MODEL_DB.reset
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.use_transactions = true
    @c.use_transactions = false 
    o.save(:y)
    MODEL_DB.sqls.should == ["BEGIN", "UPDATE items SET y = NULL WHERE (id = 3)", "COMMIT"]
    MODEL_DB.reset
  end

  it "should use :transaction option if given" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.use_transactions = true
    o.save(:y, :transaction=>false)
    MODEL_DB.sqls.should == ["UPDATE items SET y = NULL WHERE (id = 3)"]
    MODEL_DB.reset
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.use_transactions = false
    o.save(:y, :transaction=>true)
    MODEL_DB.sqls.should == ["BEGIN", "UPDATE items SET y = NULL WHERE (id = 3)", "COMMIT"]
    MODEL_DB.reset
  end

  it "should rollback if before_save returns false and raise_on_save_failure = true" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.use_transactions = true
    o.raise_on_save_failure = true
    def o.before_save
      false
    end
    proc { o.save(:y) }.should raise_error(Sequel::BeforeHookFailed)
    MODEL_DB.sqls.should == ["BEGIN", "ROLLBACK"]
    MODEL_DB.reset
  end

  it "should rollback if before_save returns false and :raise_on_failure option is true" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.use_transactions = true
    o.raise_on_save_failure = false
    def o.before_save
      false
    end
    proc { o.save(:y, :raise_on_failure => true) }.should raise_error(Sequel::BeforeHookFailed)
    MODEL_DB.sqls.should == ["BEGIN", "ROLLBACK"]
    MODEL_DB.reset
  end

  it "should not rollback outer transactions if before_save returns false and raise_on_save_failure = false" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.use_transactions = true
    o.raise_on_save_failure = false
    def o.before_save
      false
    end
    MODEL_DB.transaction do
      o.save(:y).should == nil
      MODEL_DB.run "BLAH"
    end
    MODEL_DB.sqls.should == ["BEGIN", "BLAH", "COMMIT"]
    MODEL_DB.reset
  end

  it "should rollback if before_save returns false and raise_on_save_failure = false" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.use_transactions = true
    o.raise_on_save_failure = false
    def o.before_save
      false
    end
    o.save(:y).should == nil
    MODEL_DB.sqls.should == ["BEGIN", "ROLLBACK"]
    MODEL_DB.reset
  end

  it "should not rollback if before_save throws Rollback and use_transactions = false" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.use_transactions = false
    def o.before_save
      raise Sequel::Rollback
    end
    proc { o.save(:y) }.should raise_error(Sequel::Rollback)
    MODEL_DB.sqls.should == []
    MODEL_DB.reset
  end
end

describe "Model#marshallable" do
  before do
    class ::Album < Sequel::Model
      columns :id, :x
    end
    Album.dataset.meta_def(:insert){|h| super(h); 1}
  end
  after do
    Object.send(:remove_const, :Album)
  end

  it "should make an object marshallable" do
    i = Album.new(:x=>2)
    s = nil
    i2 = nil
    i.marshallable!
    proc{s = Marshal.dump(i)}.should_not raise_error
    proc{i2 = Marshal.load(s)}.should_not raise_error
    i2.should == i

    i.save
    i.marshallable!
    proc{s = Marshal.dump(i)}.should_not raise_error
    proc{i2 = Marshal.load(s)}.should_not raise_error
    i2.should == i

    i.save
    i.marshallable!
    proc{s = Marshal.dump(i)}.should_not raise_error
    proc{i2 = Marshal.load(s)}.should_not raise_error
    i2.should == i
  end
end

describe "Model#modified[!?]" do
  before do
    @c = Class.new(Sequel::Model(:items))
    @c.class_eval do
      columns :id, :x
      @db_schema = {:x => {:type => :integer}}
    end
    MODEL_DB.reset
  end
  
  it "should be true if the object is new" do
    @c.new.modified?.should == true
  end
  
  it "should be false if the object has not been modified" do
    @c.load(:id=>1).modified?.should == false
  end
  
  it "should be true if the object has been modified" do
    o = @c.load(:id=>1, :x=>2)
    o.x = 3
    o.modified?.should == true
  end
  
  it "should be true if the object is marked modified!" do
    o = @c.load(:id=>1, :x=>2)
    o.modified!
    o.modified?.should == true
  end
  
  it "should be false if the object is marked modified! after saving until modified! again" do
    o = @c.load(:id=>1, :x=>2)
    o.modified!
    o.save
    o.modified?.should == false
    o.modified!
    o.modified?.should == true
  end
  
  it "should be false if a column value is set that is the same as the current value after typecasting" do
    o = @c.load(:id=>1, :x=>2)
    o.x = '2'
    o.modified?.should == false
  end
  
  it "should be true if a column value is set that is the different as the current value after typecasting" do
    o = @c.load(:id=>1, :x=>'2')
    o.x = '2'
    o.modified?.should == true
  end
end

describe "Model#save_changes" do
  
  before do
    @c = Class.new(Sequel::Model(:items)) do
      unrestrict_primary_key
      columns :id, :x, :y
    end
    MODEL_DB.reset
  end
  
  it "should always save if the object is new" do
    o = @c.new(:x => 1)
    o.save_changes
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (1)"
  end

  it "should take options passed to save" do
    o = @c.new(:x => 1)
    def o.before_validation; false; end
    proc{o.save_changes}.should raise_error(Sequel::Error)
    MODEL_DB.sqls.should == []
    o.save_changes(:validate=>false)
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (1)"
  end

  it "should do nothing if no changed columns" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.save_changes
    MODEL_DB.sqls.should == []
  end
  
  it "should do nothing if modified? is false" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    def o.modified?; false; end
    o.save_changes
    MODEL_DB.sqls.should == []
  end
  
  it "should update only changed columns" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.x = 2

    o.save_changes
    MODEL_DB.sqls.should == ["UPDATE items SET x = 2 WHERE (id = 3)"]
    o.save_changes
    o.save_changes
    MODEL_DB.sqls.should == ["UPDATE items SET x = 2 WHERE (id = 3)"]
    MODEL_DB.reset

    o.y = 4
    o.save_changes
    MODEL_DB.sqls.should == ["UPDATE items SET y = 4 WHERE (id = 3)"]
    o.save_changes
    o.save_changes
    MODEL_DB.sqls.should == ["UPDATE items SET y = 4 WHERE (id = 3)"]
  end
  
  it "should not consider columns changed if the values did not change" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.x = 1

    o.save_changes
    MODEL_DB.sqls.should == []
    o.x = 3
    o.save_changes
    MODEL_DB.sqls.should == ["UPDATE items SET x = 3 WHERE (id = 3)"]
    MODEL_DB.reset

    o[:y] = nil
    o.save_changes
    MODEL_DB.sqls.should == []
    o[:y] = 4
    o.save_changes
    MODEL_DB.sqls.should == ["UPDATE items SET y = 4 WHERE (id = 3)"]
  end
  
  it "should clear changed_columns" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    o.x = 4
    o.changed_columns.should == [:x]
    o.save_changes
    o.changed_columns.should == []
  end

  it "should update columns changed in a before_update hook" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    @c.send(:define_method, :before_update){self.x += 1}
    o.save_changes
    MODEL_DB.sqls.should == []
    o.x = 2
    o.save_changes
    MODEL_DB.sqls.should == ["UPDATE items SET x = 3 WHERE (id = 3)"]
    MODEL_DB.reset
    o.save_changes
    MODEL_DB.sqls.should == []
    o.x = 4
    o.save_changes
    MODEL_DB.sqls.should == ["UPDATE items SET x = 5 WHERE (id = 3)"]
    MODEL_DB.reset
  end

  it "should update columns changed in a before_save hook" do
    o = @c.load(:id => 3, :x => 1, :y => nil)
    @c.send(:define_method, :before_update){self.x += 1}
    o.save_changes
    MODEL_DB.sqls.should == []
    o.x = 2
    o.save_changes
    MODEL_DB.sqls.should == ["UPDATE items SET x = 3 WHERE (id = 3)"]
    MODEL_DB.reset
    o.save_changes
    MODEL_DB.sqls.should == []
    o.x = 4
    o.save_changes
    MODEL_DB.sqls.should == ["UPDATE items SET x = 5 WHERE (id = 3)"]
    MODEL_DB.reset
  end
end

describe "Model#new?" do
  
  before(:each) do
    MODEL_DB.reset

    @c = Class.new(Sequel::Model(:items)) do
      unrestrict_primary_key
      columns :x
    end
  end
  
  it "should be true for a new instance" do
    n = @c.new(:x => 1)
    n.should be_new
  end
  
  it "should be false after saving" do
    n = @c.new(:x => 1)
    n.save
    n.should_not be_new
  end
end

describe Sequel::Model, "w/ primary key" do
  
  it "should default to ':id'" do
    model_a = Class.new Sequel::Model
    model_a.primary_key.should be_equal(:id)
  end

  it "should be changed through 'set_primary_key'" do
    model_a = Class.new(Sequel::Model) { set_primary_key :a }
    model_a.primary_key.should be_equal(:a)
  end

  it "should support multi argument composite keys" do
    model_a = Class.new(Sequel::Model) { set_primary_key :a, :b }
    model_a.primary_key.should be_eql([:a, :b])
  end

  it "should accept single argument composite keys" do
    model_a = Class.new(Sequel::Model) { set_primary_key [:a, :b] }
    model_a.primary_key.should be_eql([:a, :b])
  end
  
end

describe Sequel::Model, "w/o primary key" do
  it "should return nil for primary key" do
    Class.new(Sequel::Model) { no_primary_key }.primary_key.should be_nil
  end

  it "should raise a Sequel::Error on 'this'" do
    instance = Class.new(Sequel::Model) { no_primary_key }.new
    proc { instance.this }.should raise_error(Sequel::Error)
  end
end

describe Sequel::Model, "with this" do

  before { @example = Class.new Sequel::Model(:examples); @example.columns :id, :a, :x, :y }

  it "should return a dataset identifying the record" do
    instance = @example.load :id => 3
    instance.this.sql.should be_eql("SELECT * FROM examples WHERE (id = 3) LIMIT 1")
  end

  it "should support arbitary primary keys" do
    @example.set_primary_key :a

    instance = @example.load :a => 3
    instance.this.sql.should be_eql("SELECT * FROM examples WHERE (a = 3) LIMIT 1")
  end

  it "should support composite primary keys" do
    @example.set_primary_key :x, :y
    instance = @example.load :x => 4, :y => 5

    parts = [
      'SELECT * FROM examples WHERE %s LIMIT 1',
      '((x = 4) AND (y = 5))', 
      '((y = 5) AND (x = 4))'
    ].map { |expr| Regexp.escape expr }
    regexp = Regexp.new parts.first % "(?:#{parts[1]}|#{parts[2]})"

    instance.this.sql.should match(regexp)
  end

end

describe "Model#pk" do
  before(:each) do
    @m = Class.new(Sequel::Model)
    @m.columns :id, :x, :y
  end
  
  it "should be default return the value of the :id column" do
    m = @m.load(:id => 111, :x => 2, :y => 3)
    m.pk.should == 111
  end

  it "should be return the primary key value for custom primary key" do
    @m.set_primary_key :x
    m = @m.load(:id => 111, :x => 2, :y => 3)
    m.pk.should == 2
  end

  it "should be return the primary key value for composite primary key" do
    @m.set_primary_key [:y, :x]
    m = @m.load(:id => 111, :x => 2, :y => 3)
    m.pk.should == [3, 2]
  end

  it "should raise if no primary key" do
    @m.set_primary_key nil
    m = @m.new(:id => 111, :x => 2, :y => 3)
    proc {m.pk}.should raise_error(Sequel::Error)

    @m.no_primary_key
    m = @m.new(:id => 111, :x => 2, :y => 3)
    proc {m.pk}.should raise_error(Sequel::Error)
  end
end

describe "Model#pk_hash" do
  before(:each) do
    @m = Class.new(Sequel::Model)
    @m.columns :id, :x, :y
  end
  
  it "should be default return the value of the :id column" do
    m = @m.load(:id => 111, :x => 2, :y => 3)
    m.pk_hash.should == {:id => 111}
  end

  it "should be return the primary key value for custom primary key" do
    @m.set_primary_key :x
    m = @m.load(:id => 111, :x => 2, :y => 3)
    m.pk_hash.should == {:x => 2}
  end

  it "should be return the primary key value for composite primary key" do
    @m.set_primary_key [:y, :x]
    m = @m.load(:id => 111, :x => 2, :y => 3)
    m.pk_hash.should == {:y => 3, :x => 2}
  end

  it "should raise if no primary key" do
    @m.set_primary_key nil
    m = @m.new(:id => 111, :x => 2, :y => 3)
    proc {m.pk_hash}.should raise_error(Sequel::Error)

    @m.no_primary_key
    m = @m.new(:id => 111, :x => 2, :y => 3)
    proc {m.pk_hash}.should raise_error(Sequel::Error)
  end
end

describe Sequel::Model, "#set" do
  before do
    MODEL_DB.reset
    
    @c = Class.new(Sequel::Model(:items)) do
      set_primary_key :id
      columns :x, :y, :id
    end
    @c.strict_param_setting = false
    @c.instance_variable_set(:@columns, true)
    @o1 = @c.new
    @o2 = @c.load(:id => 5)
  end

  it "should filter the given params using the model columns" do
    @o1.set(:x => 1, :z => 2)
    @o1.values.should == {:x => 1}
    MODEL_DB.sqls.should == []

    @o2.set(:y => 1, :abc => 2)
    @o2.values.should == {:y => 1, :id=> 5}
    MODEL_DB.sqls.should == []
  end
  
  it "should work with both strings and symbols" do
    @o1.set('x'=> 1, 'z'=> 2)
    @o1.values.should == {:x => 1}
    MODEL_DB.sqls.should == []

    @o2.set('y'=> 1, 'abc'=> 2)
    @o2.values.should == {:y => 1, :id=> 5}
    MODEL_DB.sqls.should == []
  end
  
  it "should support virtual attributes" do
    @c.send(:define_method, :blah=){|v| self.x = v}
    @o1.set(:blah => 333)
    @o1.values.should == {:x => 333}
    MODEL_DB.sqls.should == []
    @o1.set('blah'=> 334)
    @o1.values.should == {:x => 334}
    MODEL_DB.sqls.should == []
  end
  
  it "should not modify the primary key" do
    @o1.set(:x => 1, :id => 2)
    @o1.values.should == {:x => 1}
    MODEL_DB.sqls.should == []
    @o2.set('y'=> 1, 'id'=> 2)
    @o2.values.should == {:y => 1, :id=> 5}
    MODEL_DB.sqls.should == []
  end

  it "should return self" do
    returned_value = @o1.set(:x => 1, :z => 2)
    returned_value.should == @o1
    MODEL_DB.sqls.should == []
  end

  it "#set should correctly handle cases where an instance method is added to the class" do
    @o1.set(:x => 1)
    @o1.values.should == {:x => 1}

    @c.class_eval do
      def z=(v)
        self[:z] = v
      end
    end
    @o1.set(:x => 2, :z => 3)
    @o1.values.should == {:x => 2, :z=>3}
  end

  it "#set should correctly handle cases where a singleton method is added to the object" do
    @o1.set(:x => 1)
    @o1.values.should == {:x => 1}

    def @o1.z=(v)
      self[:z] = v
    end
    @o1.set(:x => 2, :z => 3)
    @o1.values.should == {:x => 2, :z=>3}
  end
end

describe Sequel::Model, "#update" do
  before do
    MODEL_DB.reset
    
    @c = Class.new(Sequel::Model(:items)) do
      set_primary_key :id
      columns :x, :y, :id
    end
    @c.strict_param_setting = false
    @c.instance_variable_set(:@columns, true)
    @o1 = @c.new
    @o2 = @c.load(:id => 5)
  end
  
  it "should filter the given params using the model columns" do
    @o1.update(:x => 1, :z => 2)
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (1)"

    MODEL_DB.reset
    @o2.update(:y => 1, :abc => 2)
    MODEL_DB.sqls.first.should == "UPDATE items SET y = 1 WHERE (id = 5)"
  end
  
  it "should support virtual attributes" do
    @c.send(:define_method, :blah=){|v| self.x = v}
    @o1.update(:blah => 333)
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (333)"
  end
  
  it "should not modify the primary key" do
    @o1.update(:x => 1, :id => 2)
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (1)"
    MODEL_DB.reset
    @o2.update('y'=> 1, 'id'=> 2)
    @o2.values.should == {:y => 1, :id=> 5}
    MODEL_DB.sqls.first.should == "UPDATE items SET y = 1 WHERE (id = 5)"
  end
end

describe Sequel::Model, "#set_fields" do
  before do
    @c = Class.new(Sequel::Model(:items))
    @c.class_eval do
      set_primary_key :id
      columns :x, :y, :z, :id
    end
    @c.strict_param_setting = true 
    @o1 = @c.new
    MODEL_DB.reset
  end

  it "should set only the given fields" do
    @o1.set_fields({:x => 1, :y => 2, :z=>3, :id=>4}, [:x, :y])
    @o1.values.should == {:x => 1, :y => 2}
    @o1.set_fields({:x => 9, :y => 8, :z=>6, :id=>7}, [:x, :y, :id])
    @o1.values.should == {:x => 9, :y => 8, :id=>7}
    MODEL_DB.sqls.should == []
  end
end

describe Sequel::Model, "#update_fields" do
  before do
    @c = Class.new(Sequel::Model(:items))
    @c.class_eval do
      set_primary_key :id
      columns :x, :y, :z, :id
      def _refresh(ds); end
    end
    @c.strict_param_setting = true 
    @o1 = @c.load(:id=>1)
    MODEL_DB.reset
  end

  it "should set only the given fields, and then save the changes to the record" do
    @o1.update_fields({:x => 1, :y => 2, :z=>3, :id=>4}, [:x, :y])
    @o1.values.should == {:x => 1, :y => 2, :id=>1}
    MODEL_DB.sqls.first.should =~ /UPDATE items SET [xy] = [12], [xy] = [12] WHERE \(id = 1\)/
    MODEL_DB.sqls.length.should == 1
    MODEL_DB.reset

    @o1.update_fields({:x => 1, :y => 5, :z=>6, :id=>7}, [:x, :y])
    @o1.values.should == {:x => 1, :y => 5, :id=>1}
    MODEL_DB.sqls.should == ["UPDATE items SET y = 5 WHERE (id = 1)"]
    MODEL_DB.reset
  end
end

describe Sequel::Model, "#(set|update)_(all|except|only)" do
  before do
    MODEL_DB.reset
    
    @c = Class.new(Sequel::Model(:items)) do
      set_primary_key :id
      columns :x, :y, :z, :id
      set_allowed_columns :x
      set_restricted_columns :y
    end
    @c.strict_param_setting = false
    @c.instance_variable_set(:@columns, true)
    @o1 = @c.new
  end

  it "should raise errors if not all hash fields can be set and strict_param_setting is true" do
    @c.strict_param_setting = true

    proc{@c.new.set_all(:x => 1, :y => 2, :z=>3, :id=>4)}.should raise_error(Sequel::Error)
    (o = @c.new).set_all(:x => 1, :y => 2, :z=>3)
    o.values.should == {:x => 1, :y => 2, :z=>3}

    proc{@c.new.set_only({:x => 1, :y => 2, :z=>3, :id=>4}, :x, :y)}.should raise_error(Sequel::Error)
    proc{@c.new.set_only({:x => 1, :y => 2, :z=>3}, :x, :y)}.should raise_error(Sequel::Error)
    (o = @c.new).set_only({:x => 1, :y => 2}, :x, :y)
    o.values.should == {:x => 1, :y => 2}

    proc{@c.new.set_except({:x => 1, :y => 2, :z=>3, :id=>4}, :x, :y)}.should raise_error(Sequel::Error)
    proc{@c.new.set_except({:x => 1, :y => 2, :z=>3}, :x, :y)}.should raise_error(Sequel::Error)
    (o = @c.new).set_except({:z => 3}, :x, :y)
    o.values.should == {:z=>3}
  end

  it "#set_all should set all attributes except the primary key" do
    @o1.set_all(:x => 1, :y => 2, :z=>3, :id=>4)
    @o1.values.should == {:x => 1, :y => 2, :z=>3}
  end

  it "#set_only should only set given attributes" do
    @o1.set_only({:x => 1, :y => 2, :z=>3, :id=>4}, [:x, :y])
    @o1.values.should == {:x => 1, :y => 2}
    @o1.set_only({:x => 4, :y => 5, :z=>6, :id=>7}, :x, :y)
    @o1.values.should == {:x => 4, :y => 5}
    @o1.set_only({:x => 9, :y => 8, :z=>6, :id=>7}, :x, :y, :id)
    @o1.values.should == {:x => 9, :y => 8, :id=>7}
  end

  it "#set_except should not set given attributes or the primary key" do
    @o1.set_except({:x => 1, :y => 2, :z=>3, :id=>4}, [:y, :z])
    @o1.values.should == {:x => 1}
    @o1.set_except({:x => 4, :y => 2, :z=>3, :id=>4}, :y, :z)
    @o1.values.should == {:x => 4}
  end

  it "#update_all should update all attributes" do
    @c.new.update_all(:x => 1, :id=>4)
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (1)"
    MODEL_DB.reset
    @c.new.update_all(:y => 1, :id=>4)
    MODEL_DB.sqls.first.should == "INSERT INTO items (y) VALUES (1)"
    MODEL_DB.reset
    @c.new.update_all(:z => 1, :id=>4)
    MODEL_DB.sqls.first.should == "INSERT INTO items (z) VALUES (1)"
  end

  it "#update_only should only update given attributes" do
    @o1.update_only({:x => 1, :y => 2, :z=>3, :id=>4}, [:x])
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (1)"
    MODEL_DB.reset
    @c.new.update_only({:x => 1, :y => 2, :z=>3, :id=>4}, :x)
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (1)"
  end

  it "#update_except should not update given attributes" do
    @o1.update_except({:x => 1, :y => 2, :z=>3, :id=>4}, [:y, :z])
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (1)"
    MODEL_DB.reset
    @c.new.update_except({:x => 1, :y => 2, :z=>3, :id=>4}, :y, :z)
    MODEL_DB.sqls.first.should == "INSERT INTO items (x) VALUES (1)"
  end
end

describe Sequel::Model, "#destroy" do
  before do
    MODEL_DB.reset
    @model = Class.new(Sequel::Model(:items))
    @model.columns :id
    @model.dataset.meta_def(:delete){MODEL_DB.execute delete_sql;1}
    
    @instance = @model.load(:id => 1234)
  end

  it "should return self" do
    @model.send(:define_method, :after_destroy){3}
    @instance.destroy.should == @instance
  end
  
  it "should raise a NoExistingObject exception if the dataset delete call doesn't return 1" do
    @instance.this.meta_def(:delete){|*a| 0}
    proc{@instance.delete}.should raise_error(Sequel::NoExistingObject)
    @instance.this.meta_def(:delete){|*a| 2}
    proc{@instance.delete}.should raise_error(Sequel::NoExistingObject)
    @instance.this.meta_def(:delete){|*a| 1}
    proc{@instance.delete}.should_not raise_error
    
    @instance.require_modification = false
    @instance.this.meta_def(:delete){|*a| 0}
    proc{@instance.delete}.should_not raise_error
    @instance.this.meta_def(:delete){|*a| 2}
    proc{@instance.delete}.should_not raise_error
  end

  it "should run within a transaction if use_transactions is true" do
    @instance.use_transactions = true
    @model.db.should_receive(:transaction)
    @instance.destroy
  end

  it "should not run within a transaction if use_transactions is false" do
    @instance.use_transactions = false
    @model.db.should_not_receive(:transaction)
    @instance.destroy
  end

  it "should run within a transaction if :transaction option is true" do
    @instance.use_transactions = false
    @model.db.should_receive(:transaction)
    @instance.destroy(:transaction => true)
  end

  it "should not run within a transaction if :transaction option is false" do
    @instance.use_transactions = true
    @model.db.should_not_receive(:transaction)
    @instance.destroy(:transaction => false)
  end

  it "should run before_destroy and after_destroy hooks" do
    @model.send(:define_method, :before_destroy){MODEL_DB.execute('before blah')}
    @model.send(:define_method, :after_destroy){MODEL_DB.execute('after blah')}
    @instance.destroy
    
    MODEL_DB.sqls.should == [
      "before blah",
      "DELETE FROM items WHERE (id = 1234)",
      "after blah"
    ]
  end
end

describe Sequel::Model, "#exists?" do
  before(:each) do
    @model = Class.new(Sequel::Model(:items))
    @ds = @model.dataset
    def @ds.fetch_rows(sql)
      db.execute(sql)
      yield(:x=>1) if sql =~ /id = 1/
    end
    MODEL_DB.reset
  end

  it "should do a query to check if the record exists" do
    @model.load(:id=>1).exists?.should be_true
    MODEL_DB.sqls.should == ['SELECT 1 FROM items WHERE (id = 1) LIMIT 1']
  end

  it "should return false when #this.count == 0" do
    @model.load(:id=>2).exists?.should be_false
    MODEL_DB.sqls.should == ['SELECT 1 FROM items WHERE (id = 2) LIMIT 1']
  end
end

describe Sequel::Model, "#each" do
  before do
    @model = Class.new(Sequel::Model(:items))
    @model.columns :a, :b, :id
    @m = @model.load(:a => 1, :b => 2, :id => 4444)
  end
  
  specify "should iterate over the values" do
    h = {}
    @m.each {|k, v| h[k] = v}
    h.should == {:a => 1, :b => 2, :id => 4444}
  end
end

describe Sequel::Model, "#keys" do
  before do
    @model = Class.new(Sequel::Model(:items))
    @model.columns :a, :b, :id
    @m = @model.load(:a => 1, :b => 2, :id => 4444)
  end
  
  specify "should return the value keys" do
    @m.keys.size.should == 3
    @m.keys.should include(:a, :b, :id)
    
    @m = @model.new()
    @m.keys.should == []
  end
end

describe Sequel::Model, "#==" do
  specify "should compare instances by values" do
    z = Class.new(Sequel::Model)
    z.columns :id, :x
    a = z.load(:id => 1, :x => 3)
    b = z.load(:id => 1, :x => 4)
    c = z.load(:id => 1, :x => 3)
    
    a.should_not == b
    a.should == c
    b.should_not == c
  end

  specify "should be aliased to #eql?" do
    z = Class.new(Sequel::Model)
    z.columns :id, :x
    a = z.load(:id => 1, :x => 3)
    b = z.load(:id => 1, :x => 4)
    c = z.load(:id => 1, :x => 3)
    
    a.eql?(b).should == false
    a.eql?(c).should == true
    b.eql?(c).should == false
  end
end

describe Sequel::Model, "#===" do
  specify "should compare instances by class and pk if pk is not nil" do
    z = Class.new(Sequel::Model)
    z.columns :id, :x
    y = Class.new(Sequel::Model)
    y.columns :id, :x
    a = z.load(:id => 1, :x => 3)
    b = z.load(:id => 1, :x => 4)
    c = z.load(:id => 2, :x => 3)
    d = y.load(:id => 1, :x => 3)
    
    a.should === b
    a.should_not === c
    a.should_not === d
  end

  specify "should always be false if the primary key is nil" do
    z = Class.new(Sequel::Model)
    z.columns :id, :x
    y = Class.new(Sequel::Model)
    y.columns :id, :x
    a = z.new(:x => 3)
    b = z.new(:x => 4)
    c = z.new(:x => 3)
    d = y.new(:x => 3)
    
    a.should_not === b
    a.should_not === c
    a.should_not === d
  end
end

describe Sequel::Model, "#hash" do
  specify "should be the same only for objects with the same class and pk if the pk is not nil" do
    z = Class.new(Sequel::Model)
    z.columns :id, :x
    y = Class.new(Sequel::Model)
    y.columns :id, :x
    a = z.load(:id => 1, :x => 3)
    b = z.load(:id => 1, :x => 4)
    c = z.load(:id => 2, :x => 3)
    d = y.load(:id => 1, :x => 3)
    
    a.hash.should == b.hash
    a.hash.should_not == c.hash
    a.hash.should_not == d.hash
  end

  specify "should be the same only for objects with the same class and values if the pk is nil" do
    z = Class.new(Sequel::Model)
    z.columns :id, :x
    y = Class.new(Sequel::Model)
    y.columns :id, :x
    a = z.new(:x => 3)
    b = z.new(:x => 4)
    c = z.new(:x => 3)
    d = y.new(:x => 3)
    
    a.hash.should_not == b.hash
    a.hash.should == c.hash
    a.hash.should_not == d.hash
  end
end

describe Sequel::Model, "#initialize" do
  before do
    @c = Class.new(Sequel::Model) do
      columns :id, :x
    end
    @c.strict_param_setting = false
  end
  
  specify "should accept values" do
    m = @c.new(:x => 2)
    m.values.should == {:x => 2}
  end
  
  specify "should not modify the primary key" do
    m = @c.new(:id => 1, :x => 2)
    m.values.should == {:x => 2}
  end
  
  specify "should accept no values" do
    m = @c.new
    m.values.should == {}
  end
  
  specify "should accept a block to execute" do
    m = @c.new {|o| o[:id] = 1234}
    m.id.should == 1234
  end
  
  specify "should accept virtual attributes" do
    @c.send(:define_method, :blah=){|x| @blah = x}
    @c.send(:define_method, :blah){@blah}
    
    m = @c.new(:x => 2, :blah => 3)
    m.values.should == {:x => 2}
    m.blah.should == 3
  end
  
  specify "should convert string keys into symbol keys" do
    m = @c.new('x' => 2)
    m.values.should == {:x => 2}
  end
end

describe Sequel::Model, ".create" do

  before(:each) do
    MODEL_DB.reset
    @c = Class.new(Sequel::Model(:items)) do
      unrestrict_primary_key
      columns :x
    end
  end

  it "should be able to create rows in the associated table" do
    o = @c.create(:x => 1)
    o.class.should == @c
    MODEL_DB.sqls.should == ['INSERT INTO items (x) VALUES (1)',  "SELECT * FROM items WHERE (id IN ('INSERT INTO items (x) VALUES (1)')) LIMIT 1"]
  end

  it "should be able to create rows without any values specified" do
    o = @c.create
    o.class.should == @c
    MODEL_DB.sqls.should == ["INSERT INTO items DEFAULT VALUES", "SELECT * FROM items WHERE (id IN ('INSERT INTO items DEFAULT VALUES')) LIMIT 1"]
  end

  it "should accept a block and run it" do
    o1, o2, o3 =  nil, nil, nil
    o = @c.create {|o4| o1 = o4; o3 = o4; o2 = :blah; o3.x = 333}
    o.class.should == @c
    o1.should === o
    o3.should === o
    o2.should == :blah
    MODEL_DB.sqls.should == ["INSERT INTO items (x) VALUES (333)", "SELECT * FROM items WHERE (id IN ('INSERT INTO items (x) VALUES (333)')) LIMIT 1"]
  end
  
  it "should create a row for a model with custom primary key" do
    @c.set_primary_key :x
    o = @c.create(:x => 30)
    o.class.should == @c
    MODEL_DB.sqls.should == ["INSERT INTO items (x) VALUES (30)", "SELECT * FROM items WHERE (x = 30) LIMIT 1"]
  end
end

describe Sequel::Model, "#refresh" do
  before do
    MODEL_DB.reset
    @c = Class.new(Sequel::Model(:items)) do
      unrestrict_primary_key
      columns :id, :x
    end
  end

  specify "should reload the instance values from the database" do
    @m = @c.new(:id => 555)
    @m[:x] = 'blah'
    @m.this.should_receive(:first).and_return({:x => 'kaboom', :id => 555})
    @m.refresh
    @m[:x].should == 'kaboom'
  end
  
  specify "should raise if the instance is not found" do
    @m = @c.new(:id => 555)
    @m.this.should_receive(:first).and_return(nil)
    proc {@m.refresh}.should raise_error(Sequel::Error)
  end
  
  specify "should be aliased by #reload" do
    @m = @c.new(:id => 555)
    @m.this.should_receive(:first).and_return({:x => 'kaboom', :id => 555})
    @m.reload
    @m[:x].should == 'kaboom'
  end

  specify "should remove cached associations" do
    @c.many_to_one :node, :class=>@c
    @m = @c.new(:id => 555)
    @m.associations[:node] = 15
    @m.reload
    @m.associations.should == {}
  end
end

describe Sequel::Model, "typecasting" do
  before do
    MODEL_DB.reset
    @c = Class.new(Sequel::Model(:items)) do
      columns :x
    end
  end

  after do
    Sequel.datetime_class = Time
  end

  specify "should not convert if typecasting is turned off" do
    @c.typecast_on_assignment = false
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:integer}})
    m = @c.new
    m.x = '1'
    m.x.should == '1'
  end

  specify "should convert to integer for an integer field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:integer}})
    m = @c.new
    m.x = '1'
    m.x.should == 1
    m.x = 1
    m.x.should == 1
    m.x = 1.3
    m.x.should == 1
  end

  specify "should typecast '' to nil unless type is string or blob" do
    [:integer, :float, :decimal, :boolean, :date, :time, :datetime].each do |x|
      @c.instance_variable_set(:@db_schema, {:x=>{:type=>x}})
      m = @c.new
      m.x = ''
      m.x.should == nil
    end
   [:string, :blob].each do |x|
      @c.instance_variable_set(:@db_schema, {:x=>{:type=>x}})
      m = @c.new
      m.x = ''
      m.x.should == ''
    end
  end

  specify "should not typecast '' to nil if typecast_empty_string_to_nil is false" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:integer}})
    m = @c.new
    m.typecast_empty_string_to_nil = false
    proc{m.x = ''}.should raise_error
    @c.typecast_empty_string_to_nil = false
    proc{@c.new.x = ''}.should raise_error
  end

  specify "should not typecast nil if NULLs are allowed" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:integer,:allow_null=>true}})
    m = @c.new
    m.x = nil
    m.x.should == nil
  end

  specify "should raise an error if attempting to typecast nil and NULLs are not allowed" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:integer,:allow_null=>false}})
    proc{@c.new.x = nil}.should raise_error(Sequel::Error)
    proc{@c.new.x = ''}.should raise_error(Sequel::Error)
  end

  specify "should not raise an error if NULLs are not allowed and typecasting is turned off" do
    @c.typecast_on_assignment = false
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:integer,:allow_null=>false}})
    m = @c.new
    m.x = nil
    m.x.should == nil
  end

  specify "should not raise when typecasting nil to NOT NULL column but raise_on_typecast_failure is off" do
    @c.raise_on_typecast_failure = false
    @c.typecast_on_assignment = true
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:integer,:allow_null=>false}})
    m = @c.new
    m.x = ''
    m.x.should == nil
    m.x = nil
    m.x.should == nil
  end

  specify "should raise an error if invalid data is used in an integer field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:integer}})
    proc{@c.new.x = 'a'}.should raise_error(Sequel::InvalidValue)
  end

  specify "should assign value if raise_on_typecast_failure is off and assigning invalid integer" do
    @c.raise_on_typecast_failure = false
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:integer}})
    model = @c.new
    model.x = '1d'
    model.x.should == '1d'
  end

  specify "should convert to float for a float field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:float}})
    m = @c.new
    m.x = '1.3'
    m.x.should == 1.3
    m.x = 1
    m.x.should == 1.0
    m.x = 1.3
    m.x.should == 1.3
  end

  specify "should raise an error if invalid data is used in an float field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:float}})
    proc{@c.new.x = 'a'}.should raise_error(Sequel::InvalidValue)
  end

  specify "should assign value if raise_on_typecast_failure is off and assigning invalid float" do
    @c.raise_on_typecast_failure = false
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:float}})
    model = @c.new
    model.x = '1d'
    model.x.should == '1d'
  end

  specify "should convert to BigDecimal for a decimal field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:decimal}})
    m = @c.new
    bd = BigDecimal.new('1.0')
    m.x = '1.0'
    m.x.should == bd
    m.x = 1.0
    m.x.should == bd
    m.x = 1
    m.x.should == bd
    m.x = bd
    m.x.should == bd
  end

  specify "should raise an error if invalid data is used in an decimal field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:decimal}})
    proc{@c.new.x = Date.today}.should raise_error(Sequel::InvalidValue)
  end

  specify "should assign value if raise_on_typecast_failure is off and assigning invalid decimal" do
    @c.raise_on_typecast_failure = false
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:decimal}})
    model = @c.new
    time = Time.now
    model.x = time
    model.x.should == time
  end

  specify "should convert to string for a string field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:string}})
    m = @c.new
    m.x = '1.3'
    m.x.should == '1.3'
    m.x = 1
    m.x.should == '1'
    m.x = 1.3
    m.x.should == '1.3'
  end

  specify "should convert to boolean for a boolean field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:boolean}})
    m = @c.new
    m.x = '1.3'
    m.x.should == true
    m.x = 1
    m.x.should == true
    m.x = 1.3
    m.x.should == true
    m.x = 't'
    m.x.should == true
    m.x = 'T'
    m.x.should == true
    m.x = true
    m.x.should == true
    m.x = nil
    m.x.should == nil
    m.x = ''
    m.x.should == nil
    m.x = []
    m.x.should == nil
    m.x = 'f'
    m.x.should == false
    m.x = 'F'
    m.x.should == false
    m.x = 'false'
    m.x.should == false
    m.x = 'FALSE'
    m.x.should == false
    m.x = '0'
    m.x.should == false
    m.x = 0
    m.x.should == false
    m.x = false
    m.x.should == false
  end

  specify "should convert to date for a date field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:date}})
    m = @c.new
    y = Date.new(2007,10,21)
    m.x = '2007-10-21'
    m.x.should == y
    m.x = Date.parse('2007-10-21')
    m.x.should == y
    m.x = Time.parse('2007-10-21')
    m.x.should == y
    m.x = DateTime.parse('2007-10-21')
    m.x.should == y
  end

  specify "should accept a hash with symbol or string keys for a date field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:date}})
    m = @c.new
    y = Date.new(2007,10,21)
    m.x = {:year=>2007, :month=>10, :day=>21}
    m.x.should == y
    m.x = {'year'=>'2007', 'month'=>'10', 'day'=>'21'}
    m.x.should == y
  end

  specify "should raise an error if invalid data is used in a date field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:date}})
    proc{@c.new.x = 'a'}.should raise_error(Sequel::InvalidValue)
    proc{@c.new.x = 100}.should raise_error(Sequel::InvalidValue)
  end

  specify "should assign value if raise_on_typecast_failure is off and assigning invalid date" do
    @c.raise_on_typecast_failure = false
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:date}})
    model = @c.new
    model.x = 4
    model.x.should == 4
  end

  specify "should convert to time for a time field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:time}})
    m = @c.new
    x = '10:20:30'
    y = Time.parse(x)
    m.x = x
    m.x.should == y
    m.x = y
    m.x.should == y
  end

  specify "should accept a hash with symbol or string keys for a time field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:time}})
    m = @c.new
    y = Time.parse('10:20:30')
    m.x = {:hour=>10, :minute=>20, :second=>30}
    m.x.should == y
    m.x = {'hour'=>'10', 'minute'=>'20', 'second'=>'30'}
    m.x.should == y
  end

  specify "should raise an error if invalid data is used in a time field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:time}})
    proc{@c.new.x = '0000'}.should raise_error
    proc{@c.new.x = Date.parse('2008-10-21')}.should raise_error(Sequel::InvalidValue)
    proc{@c.new.x = DateTime.parse('2008-10-21')}.should raise_error(Sequel::InvalidValue)
  end

  specify "should assign value if raise_on_typecast_failure is off and assigning invalid time" do
    @c.raise_on_typecast_failure = false
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:time}})
    model = @c.new
    model.x = '0000'
    model.x.should == '0000'
  end

  specify "should convert to the Sequel.datetime_class for a datetime field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:datetime}})
    m = @c.new
    x = '2007-10-21T10:20:30-07:00'
    y = Time.parse(x)
    m.x = x
    m.x.should == y
    m.x = DateTime.parse(x)
    m.x.should == y
    m.x = Time.parse(x)
    m.x.should == y
    m.x = Date.parse('2007-10-21')
    m.x.should == Time.parse('2007-10-21')
    Sequel.datetime_class = DateTime
    y = DateTime.parse(x)
    m.x = x
    m.x.should == y
    m.x = DateTime.parse(x)
    m.x.should == y
    m.x = Time.parse(x)
    m.x.should == y
    m.x = Date.parse('2007-10-21')
    m.x.should == DateTime.parse('2007-10-21')
  end

  specify "should accept a hash with symbol or string keys for a datetime field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:datetime}})
    m = @c.new
    y = Time.parse('2007-10-21 10:20:30')
    m.x = {:year=>2007, :month=>10, :day=>21, :hour=>10, :minute=>20, :second=>30}
    m.x.should == y
    m.x = {'year'=>'2007', 'month'=>'10', 'day'=>'21', 'hour'=>'10', 'minute'=>'20', 'second'=>'30'}
    m.x.should == y
    Sequel.datetime_class = DateTime
    y = DateTime.parse('2007-10-21 10:20:30')
    m.x = {:year=>2007, :month=>10, :day=>21, :hour=>10, :minute=>20, :second=>30}
    m.x.should == y
    m.x = {'year'=>'2007', 'month'=>'10', 'day'=>'21', 'hour'=>'10', 'minute'=>'20', 'second'=>'30'}
    m.x.should == y
  end

  specify "should raise an error if invalid data is used in a datetime field" do
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:datetime}})
    proc{@c.new.x = '0000'}.should raise_error(Sequel::InvalidValue)
    Sequel.datetime_class = DateTime
    proc{@c.new.x = '0000'}.should raise_error(Sequel::InvalidValue)
    proc{@c.new.x = 'a'}.should raise_error(Sequel::InvalidValue)
  end

  specify "should assign value if raise_on_typecast_failure is off and assigning invalid datetime" do
    @c.raise_on_typecast_failure = false
    @c.instance_variable_set(:@db_schema, {:x=>{:type=>:datetime}})
    model = @c.new
    model.x = '0000'
    model.x.should == '0000'
    Sequel.datetime_class = DateTime
    model = @c.new
    model.x = '0000'
    model.x.should == '0000'
    model.x = 'a'
    model.x.should == 'a'
  end
end

describe "Model#lock!" do
  before do
    @c = Class.new(Sequel::Model(:items)) do
      columns :id
    end
    ds = @c.dataset
    def ds.fetch_rows(sql)
      db.execute(sql)
      yield({:id=>1})
    end
    MODEL_DB.reset
  end
  
  it "should do nothing if the record is a new record" do
    o = @c.new
    called = false
    o.meta_def(:_refresh){|x| called = true; super(x)}
    x = o.lock!
    x.should == o
    called.should == false
    MODEL_DB.sqls.should == []
  end
    
  it "should refresh the record using for_update if it is not a new record" do
    o = @c.load(:id => 1)
    called = false
    o.meta_def(:_refresh){|x| called = true; super(x)}
    x = o.lock!
    x.should == o
    called.should == true
    MODEL_DB.sqls.should == ["SELECT * FROM items WHERE (id = 1) LIMIT 1 FOR UPDATE"]
  end
end
