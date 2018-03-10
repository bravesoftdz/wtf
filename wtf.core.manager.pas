unit wtf.core.manager;

{$i wtf.inc}

interface

uses
  Classes, SysUtils, wtf.core.types, wtf.core.feeder, wtf.core.classifier,
  wtf.core.persist,
  {$IFDEF FPC}
  fgl
  {$ELSE}
  System.Generics.Collections
  {$ENDIF};

type

  { TVoteEntry }
  (*
    used by model manager to keep track of votes
  *)
  TVoteEntry<TData,TClassification> = class
  private
    FModel : IModel<TData,TClassification>;
    FID : TIdentifier;
    FClassification : TClassification;
  public
    property ID : TIdentifier read FID;
    property Model : IModel<TData,TClassification> read FModel;
    property Classification : TClassification read FClassification;
    constructor Create(Const AModel : IModel<TData,TClassification>;
      Const AIdentifier : TIdentifier; Const AClassification : TClassification);
    destructor Destroy; override;
  end;

  { TModelManagerImpl }
  (*
    Base implementation of the IModelManager interface
  *)
  TModelManagerImpl<TData,TClassification> = class(TPersistableImpl,IModelManager<TData,TClassification>)
  private
    type
      TSpecializedVoteEntry = TVoteEntry<TData,TClassification>;
      TVoteEntries =
        {$IFDEF FPC}
        TFPGObjectList<TSpecializedVoteEntry>;
        {$ELSE}
        TObjectList<TSpecializedVoteEntry>;
        {$ENDIF}
      //to avoid having to overload comparison operators for TIdentifer
      //use string as the key and do a guid.tostring when looking
      TVoteMap =
        {$IFDEF FPC}
        TFPGMapObject<String,TVoteEntries>;
        {$ELSE}
        //delphi dictionary should be able to handle guid as key
        TObjectDictionary<TIdentifier,TSpecializedVoteEntry>;
        {$ENDIF}
      TWeight = 0..100;
      PWeightModel = ^IModel<TData,TClassification>;
      TWeightEntry = Record
      private
        FModel:PWeightModel;
        FWeight:TWeight;
      public
        property Model : PWeightModel read FModel write FModel;
        property Weight : TWeight read FWeight write FWeight;
        class operator Equal(Const a, b : TWeightEntry) : Boolean;
      end;
      TWeightList =
        {$IFDEF FPC}
        TFPGList<TWeightEntry>
        {$ELSE}
        TList<TWeightEntry>
        {$ENDIF};
  private
    FModels : TModels<TData,TClassification>;
    FDataFeeder : IDataFeeder<TData>;
    FClassifier : IClassifier<TData,TClassification>;
    FDataFeederSubscriber : IDataFeederSubscriber;
    FClassifierSubscriber : IClassificationSubscriber;
    FVoteMap : TVoteMap;
    FPreClass : TClassifierPubPayload;
    FAlterClass : TClassifierPubPayload;
    FWeightList : TWeightList;
    function GetModels: TModels<TData,TClassification>;
    function GetDataFeeder : IDataFeeder<TData>;
    function GetClassifier : IClassifier<TData,TClassification>;
    procedure RedirectData(Const AMessage:TDataFeederPublication);
    procedure RedirectClassification(Const AMessage:PClassifierPubPayload);
    function GetWeightedClassification(Const AEntries:TVoteEntries) : TClassification;
    procedure VerifyModels(Const AEntries:TVoteEntries);
    function ComparePayload(Const A, B : PClassifierPubPayload):TComparisonOperator;
  protected
    //children need to override these methods
    function InitDataFeeder : TDataFeederImpl<TData>;virtual;abstract;
    function InitClassifier : TClassifierImpl<TData,TClassification>;virtual;abstract;
    procedure DoPersist;override;
    procedure DoReload;override;
  public
    //properties
    property Models : TModels<TData,TClassification> read GetModels;
    property DataFeeder : IDataFeeder<TData> read GetDataFeeder;
    property Classifier : IClassifier<TData,TClassification> read GetClassifier;
    //methods
    function ProvideFeedback(Const ACorrectClassification:TClassification;
      Const AIdentifer:TIdentifier):Boolean;overload;
    function ProvideFeedback(Const ACorrectClassification:TClassification;
      Const AIdentifer:TIdentifier; Out Error:String):Boolean;overload;
    constructor Create;override;
    destructor Destroy;override;
    { TODO 3 : keep track of classifications/id's using classifier subscriber }
    { TODO 4 : Voting system in place for the model manager }
    { TODO 5 : add classification by id to classifier interface, or handle by caller? }
  end;

implementation
uses
  wtf.core.subscriber, math;

{ TVoteEntry }

constructor TVoteEntry<TData,TClassification>.Create(
  Const AModel : IModel<TData,TClassification>;
  Const AIdentifier : TIdentifier; Const AClassification : TClassification);
begin
  inherited Create;
  FModel:=AModel;
  FID:=AIdentifier;
  FClassification:=AClassification;
end;

destructor TVoteEntry<TData,TClassification>.Destroy;
begin
  FModel:=nil;
  inherited Destroy;
end;

{ TWeightEntry }

class operator TModelManagerImpl<TData,TClassification>.TWeightEntry.Equal(Const a, b : TWeightEntry) : Boolean;
begin
  Result:=a.Model=b.Model;
end;

{ TModelManagerImpl }

function TModelManagerImpl<TData,TClassification>.ComparePayload(Const A, B : PClassifierPubPayload):TComparisonOperator;
begin
  if A.PublicationType<B.PublicationType then
    Result:=coLess
  else if A.PublicationType=B.PublicationType then
    Result:=coEqual
  else
    Result:=coGreater;
end;

procedure TModelManagerImpl<TData,TClassification>.VerifyModels(Const AEntries:TVoteEntries);
var
  I,J:Integer;
  LRebalance:Boolean;
  LProportionalWeight:TWeight;
  LRemainder:TWeight;
  LWeightEntry:TWeightEntry;
  LRemove:array of Integer;
begin
  LRebalance:=False;
  SetLength(LRemove,0);
  //first make sure we don't need to add any models from entries
  for I:=0 to Pred(AEntries.Count) do
  begin
    if not Assigned(AEntries[I].Model) then
      Continue;
    LWeightEntry.Model:=@AEntries[I].Model;
    LWeightEntry.Weight:=Low(TWeight);
    if FWeightList.IndexOf(LWeightEntry)<0 then
    begin
      FWeightList.Add(LWeightEntry);
      if not LRebalance then
        LRebalance:=True;
    end;
  end;
  //next, make sure we remove any invalid entries
  for I:=0 to Pred(FWeightList.Count) do
  begin
    //first case is the model pointer we have has been removed
    if not Assigned(FWeightList[I].Model^) then
    begin
      SetLength(LRemove,Succ(Length(LRemove)));
      LRemove[High(LRemove)]:=I;
      if not LRebalance then
        LRebalance:=True;
    end;
    //next case, is that a model has been removed from the model collection
    //and is not in the entries, so we remove it
    if not AEntries.Count<>FWeightList.Count then
    begin
      for J:=0 to Pred(AEntries.Count) do
      begin
        if not Assigned(AEntries[J].Model) then
          Continue;
        LWeightEntry.Model:=@AEntries[J].Model;
        if FWeightList.IndexOf(LWeightEntry)<0 then
        begin
          SetLength(LRemove,Succ(Length(LRemove)));
          LRemove[High(LRemove)]:=I;
          if not LRebalance then
            LRebalance:=True;
        end;
      end;
    end;
  end;
  //lastly if we need to rebalance the weights, do so in a proportional manner,
  //may need to change in the future to guage off of prior weights..
  if LRebalance then
  begin
    LProportionalWeight:=Trunc(Integer(High(TWeight)) / FWeightList.Count);
    for I:=0 to Pred(FWeightList.Count) do
      FWeightList[I].Weight:=LProportionalWeight;
    LRemainder:=High(TWeight) - LProportionalWeight;
    //distribute any remainder amounts randomly
    if LRemainder>0 then
      Randomize;
    While LRemainder>0 do
    begin
      I:=RandomRange(0,FWeightList.Count);
      FWeightList[I].Weight:=FWeightList[I].Weight + 1;
      Dec(LRemainder);
    end;
  end;
end;

function TModelManagerImpl<TData,TClassification>.GetWeightedClassification(
  Const AEntries:TVoteEntries) : TClassification;
begin
  Result:=AEntries[0].Classification;
  //first make sure all entries have made it to the weight array
  VerifyModels(AEntries);
  //now for each unique classification, sum up the weights, and return the
  //highest voted for response
  //...
end;

procedure TModelManagerImpl<TData,TClassification>.RedirectClassification(
  Const AMessage:PClassifierPubPayload);
var
  LEntries:TVoteEntries;
  LEntry:TSpecializedVoteEntry;
  I:Integer;
  LClassification:TClassification;
  LIdentifier:TIdentifier;
begin
  //when someone wants to classify, we need to grab the identifier as the
  //key to a "batch" of classifications
  if AMessage.PublicationType=cpPreClassify then
  begin
    LEntries:=TVoteEntries.Create(True);
    //capture the identifier our classifier generated and use it as a key
    FVoteMap.Add(AMessage.ID.ToString,LEntries);
  end
  else if AMessage.PublicationType=cpAlterClassify then
  begin
    if not FVoteMap.Sorted then
      FVoteMap.Sorted:=True;
    //need to make sure we still have the identifier
    if not FVoteMap.Find(AMessage.ID.ToString, I) then
      Exit;
    LEntries:=FVoteMap.Data[I];
    //regardless of whatever the initialized classifier spits out as default
    //we will change it to be the aggregate response for our identifier
    for I:=0 to High(Models.Collection.Count) do
    begin
      //first add this classification to the entries
      LIdentifier:=Models.Collection[I].Classifier.Classify(LClassification);
      LEntry:=TSpecializedVoteEntry.Create(
        Models.Collection[I],
        LIdentifier,
        LClassification
      );
      LEntries.Add(LEntry);
    end;
    //now according to weight, we will get the aggregate response
    AMessage.Classification:=GetWeightedClassification(LEntries);
  end;
end;

procedure TModelManagerImpl<TData,TClassification>.RedirectData(
  Const AMessage:TDataFeederPublication);
var
  LData : TData;
  I : Integer;
begin
  if AMessage=fpPostFeed then
  begin
    if FModels.Collection.Count<=0 then
      Exit;
    //redirect the last entered data to all models
    LData:=FDataFeeder[Pred(FDataFeeder.Count)];
    for I:=0 to Pred(FModels.Collection.Count) do
      FModels.Collection[I].DataFeeder.Feed(LData);
    //before internal clearing, unsubscribe first
    FDataFeeder.Publisher.Remove(FDataFeederSubscriber,fpPostClear);
    //we don't need to hold any data, let the models do this
    FDataFeeder.Clear;
    //re-subscribe to clear for user activated clears
    FDataFeeder.Publisher.Subscribe(FDataFeederSubscriber,fpPostClear);
	end;
  //on a clear, we need to get rid of any tracking info, and clear our own feeder
  if AMessage=fpPostClear then
  begin
    FVoteMap.Clear;
    FDataFeeder.Clear;
  end;
end;

procedure TModelManagerImpl<TData,TClassification>.DoPersist;
begin
  inherited DoPersist;
  { TODO 5 : write all properties to json }
end;

procedure TModelManagerImpl<TData,TClassification>.DoReload;
begin
  inherited DoReload;
  { TODO 5 : read all properties from json }
end;

function TModelManagerImpl<TData,TClassification>.GetModels: TModels<TData,TClassification>;
begin
  Result:=FModels;
end;

function TModelManagerImpl<TData,TClassification>.GetDataFeeder : IDataFeeder<TData>;
begin
  Result:=FDataFeeder;
end;

function TModelManagerImpl<TData,TClassification>.GetClassifier : IClassifier<TData,TClassification>;
begin
  Result:=FClassifier;
end;

function TModelManagerImpl<TData,TClassification>.ProvideFeedback(
  Const ACorrectClassification:TClassification;
  Const AIdentifer:TIdentifier):Boolean;
Var
  LError:String;
begin
  Result:=ProvideFeedback(ACorrectClassification,AIdentifer,LError);
end;

function TModelManagerImpl<TData,TClassification>.ProvideFeedback(
  Const ACorrectClassification:TClassification;
  Const AIdentifer:TIdentifier; Out Error:String):Boolean;
begin
  Result:=False;
  { TODO 4 : look in vote map for id, and reward those that were successful }
end;

constructor TModelManagerImpl<TData,TClassification>.Create;
var
  LClassifier:TClassifierImpl<TData,TClassification>;
begin
  inherited Create;
  FDataFeeder:=InitDataFeeder;
  //subscribe to feeder
  FDataFeederSubscriber:=TSubscriberImpl<TDataFeederPublication>.Create;
  FDataFeederSubscriber.OnNotify:=RedirectData;
  FDataFeeder.Publisher.Subscribe(FDataFeederSubscriber,fpPostFeed);
  FDataFeeder.Publisher.Subscribe(FDataFeederSubscriber,fpPostClear);
  //subscribe to classifier, for ease just create some records privately
  //to use in case we have to un-sub later
  FPreClass.PublicationType:=cpPreClassify;
  FAlterClass.PublicationType:=cpAlterClassify;
  LClassifier:=InitClassifier;
  LClassifier.Publisher.MessageComparison.OnCompare:=ComparePayload;
  LClassifier.UpdateDataFeeder(DataFeeder);
  FClassifier:=LClassifier;
  FClassifierSubscriber:=TSubscriberImpl<PClassifierPubPayload>.Create;
  FClassifierSubscriber.OnNotify:=RedirectClassification;
  FClassifier.Publisher.Subscribe(FClassifierSubscriber,@FPreClass);
  FClassifier.Publisher.Subscribe(FClassifierSubscriber,@FAlterClass);
  FModels:=TModels<TData,TClassification>.Create;
  FVoteMap:=TVoteMap.Create(True);
  FWeightList:=TWeightList.Create;
end;

destructor TModelManagerImpl<TData,TClassification>.Destroy;
begin
  FDataFeeder:=nil;
  FDataFeederSubscriber:=nil;
  FClassifier:=nil;
  FClassifierSubscriber:=nil;
  FModels.Free;
  FVoteMap.Free;
  FWeightList.Free;
  inherited Destroy;
end;

end.

